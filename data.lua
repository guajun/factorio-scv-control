data:extend({
  {
    type = "custom-input",
    name = "scv-move-command",
    key_sequence = "mouse-button-2",
    consuming = "none",
    include_selected_prototype = true
  },
  {
    type = "custom-input",
    name = "scv-queue-move-command",
    key_sequence = "SHIFT + mouse-button-2",
    consuming = "none",
    include_selected_prototype = true
  },
  {
    type = "custom-input",
    name = "scv-block-move-up",
    key_sequence = "",
    linked_game_control = "move-up",
    consuming = "game-only"
  },
  {
    type = "custom-input",
    name = "scv-stop-command",
    key_sequence = "",
    linked_game_control = "move-down",
    consuming = "game-only"
  },
  {
    type = "custom-input",
    name = "scv-block-move-left",
    key_sequence = "",
    linked_game_control = "move-left",
    consuming = "game-only"
  },
  {
    type = "custom-input",
    name = "scv-block-move-right",
    key_sequence = "",
    linked_game_control = "move-right",
    consuming = "game-only"
  }
})
