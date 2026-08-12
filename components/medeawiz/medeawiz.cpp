#include "medeawiz.h"

#include <algorithm>

#include "esphome/core/log.h"

namespace esphome {
namespace medeawiz {

static const char* const TAG = "medeawiz";

float MedeaWiz::get_setup_priority() const { return setup_priority::DATA; }

void MedeaWiz::play_file(uint16_t file) {
  if (file > MEDEAWIZ_FILE_MAX) {
    ESP_LOGW(TAG, "File %u out of range (0-%u), ignoring", file,
             MEDEAWIZ_FILE_MAX);
    return;
  }
  ESP_LOGD(TAG, "Playing file %03u", file);
  this->send_command((uint8_t)file);
}

void MedeaWiz::set_loop_file(uint16_t file) {
  if (file > MEDEAWIZ_FILE_MAX) {
    ESP_LOGW(TAG, "Loop file %u out of range (0-%u), ignoring", file,
             MEDEAWIZ_FILE_MAX);
    return;
  }
  ESP_LOGD(TAG, "Setting loop file to %03u", file);
  const uint8_t cmd[2] = {MEDEAWIZ_CMD_SELECT_LOOP_FILE, (uint8_t)file};
  this->write_command_(cmd, 2);
}

void MedeaWiz::seek(uint32_t position_ms) {
  ESP_LOGD(TAG, "Seeking to %u ms", position_ms);
  // 0xF6 followed by the 4-byte position in milliseconds, high byte first.
  const uint8_t cmd[5] = {
      MEDEAWIZ_CMD_SEEK,
      (uint8_t)(position_ms >> 24),
      (uint8_t)(position_ms >> 16),
      (uint8_t)(position_ms >> 8),
      (uint8_t)position_ms,
  };
  this->write_command_(cmd, 5);
}

void MedeaWiz::send_command(uint8_t command) {
  this->write_command_(&command, 1);
}

void MedeaWiz::write_command_(const uint8_t* data, size_t len) {
  // In Full Reporting the Sprite echoes back every byte it receives. Remember
  // them all (address prefix included) so handle_byte_() discards the echoes
  // instead of parsing the operands as file reports or reply headers.
  if (this->feedback_mode_ == MEDEAWIZ_REPORT_FULL) {
    if (this->use_address_) this->queue_echo_(this->address_);
    for (size_t i = 0; i < len; i++) this->queue_echo_(data[i]);
  }
  if (this->use_address_) this->write_byte(this->address_);
  this->write_array(data, len);
}

void MedeaWiz::queue_echo_(uint8_t byte) {
  // Ring buffer; if it ever fills, drop the oldest so indexing stays valid.
  if (this->pending_echo_count_ == PENDING_ECHO_CAPACITY) {
    this->pending_echo_head_ =
        (this->pending_echo_head_ + 1) % PENDING_ECHO_CAPACITY;
    this->pending_echo_count_--;
  }
  uint8_t tail = (this->pending_echo_head_ + this->pending_echo_count_) %
                 PENDING_ECHO_CAPACITY;
  this->pending_echo_[tail] = byte;
  this->pending_echo_count_++;
  this->pending_echo_time_ = millis();
}

void MedeaWiz::loop() {
  // Drain the RX FIFO in batches to reduce per-byte UART call overhead.
  size_t avail = this->available();
  uint8_t buf[64];
  while (avail > 0) {
    size_t to_read = std::min(avail, sizeof(buf));
    if (!this->read_array(buf, to_read)) break;
    avail -= to_read;
    for (size_t i = 0; i < to_read; i++) this->handle_byte_(buf[i]);
  }
}

void MedeaWiz::handle_byte_(uint8_t byte) {
  // Collecting the fixed-length payload of a multi-byte reply.
  if (this->state_ != FeedbackState::IDLE) {
    this->payload_[this->payload_pos_++] = byte;
    if (this->payload_pos_ < this->payload_len_) return;
    if (this->state_ == FeedbackState::FILE_COUNT) {
      this->file_count_ = this->payload_[0];
      ESP_LOGD(TAG, "File count: %u", this->file_count_);
    } else {
      uint32_t value = ((uint32_t)this->payload_[0] << 24) |
                       ((uint32_t)this->payload_[1] << 16) |
                       ((uint32_t)this->payload_[2] << 8) |
                       (uint32_t)this->payload_[3];
      if (this->state_ == FeedbackState::POSITION) {
        this->position_ms_ = value;
        ESP_LOGD(TAG, "Position: %u ms", value);
      } else {
        this->duration_ms_ = value;
        ESP_LOGD(TAG, "Duration: %u ms", value);
      }
    }
    this->state_ = FeedbackState::IDLE;
    return;
  }

  // In Full Reporting the Sprite echoes every byte it received -- assuming it
  // echoes whole commands (the documented behaviour). Discard those echoes in
  // FIFO order so command operands aren't parsed as file reports or reply
  // headers. If the window elapses with the head unmatched (an echo that never
  // arrived), drop the queue so stale operands can't swallow reports AFTER it.
  // Caveat: a unit that echoes only the opcode would leave operands queued for
  // up to the window, where a genuine report matching the head could still be
  // missed -- use Minimal/Command-Request feedback for echo-free, exact
  // parsing.
  if (this->pending_echo_count_ > 0) {
    if (millis() - this->pending_echo_time_ > MEDEAWIZ_ECHO_WINDOW_MS) {
      this->pending_echo_head_ = 0;
      this->pending_echo_count_ = 0;
    } else if (byte == this->pending_echo_[this->pending_echo_head_]) {
      this->pending_echo_head_ =
          (this->pending_echo_head_ + 1) % PENDING_ECHO_CAPACITY;
      this->pending_echo_count_--;
      ESP_LOGV(TAG, "Discarded echoed byte 0x%02X", byte);
      return;
    }
  }

  // Idle: interpret the leading byte of a report from the Sprite.
  if (byte <= MEDEAWIZ_FILE_MAX) {
    // The Sprite periodically reports the file number currently playing; only
    // act on a change so the trigger does not fire several times per second.
    if (byte != this->current_file_) {
      this->current_file_ = byte;
      ESP_LOGD(TAG, "Now playing file %03u", byte);
      this->on_file_callback_.call(byte);
    }
  } else if (byte == MEDEAWIZ_FEEDBACK_END_OF_FILE) {
    ESP_LOGD(TAG, "End of file reached");
    this->on_end_of_file_callback_.call();
  } else if (byte == MEDEAWIZ_CMD_REQUEST_FILE_COUNT) {  // 0xCB <count>
    this->state_ = FeedbackState::FILE_COUNT;
    this->payload_pos_ = 0;
    this->payload_len_ = 1;
  } else if (byte == MEDEAWIZ_CMD_REQUEST_POSITION) {  // 0xF5 <4 bytes>
    this->state_ = FeedbackState::POSITION;
    this->payload_pos_ = 0;
    this->payload_len_ = 4;
  } else if (byte == MEDEAWIZ_CMD_GET_DURATION) {  // 0xF7 <4 bytes>
    this->state_ = FeedbackState::DURATION;
    this->payload_pos_ = 0;
    this->payload_len_ = 4;
  } else {
    // Echoed command bytes (Full Reporting mode echoes commands) and any other
    // bytes carry no state we track.
    ESP_LOGV(TAG, "Ignoring feedback byte 0x%02X", byte);
  }
}

void MedeaWiz::dump_config() {
  ESP_LOGCONFIG(TAG, "MedeaWiz Sprite:");
  if (this->use_address_) {
    ESP_LOGCONFIG(TAG, "  Address: 0x%02X", this->address_);
  } else {
    ESP_LOGCONFIG(TAG, "  Address: not used");
  }
  const char* mode = "full reporting";
  if (this->feedback_mode_ == MEDEAWIZ_REPORT_MINIMAL) {
    mode = "minimal reporting";
  } else if (this->feedback_mode_ == MEDEAWIZ_REPORT_COMMAND_REQUEST) {
    mode = "command request only";
  }
  ESP_LOGCONFIG(TAG, "  Feedback: %s", mode);
  // Validate 8N1 framing against the configured baud rate. The Sprite's baud is
  // user-selectable in its Setup Menu, so the rate itself is not constrained.
  this->check_uart_settings(this->parent_->get_baud_rate());
}

}  // namespace medeawiz
}  // namespace esphome
