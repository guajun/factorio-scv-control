data:extend({
  {
    type = "int-setting",
    name = "scv-command-queue-limit",
    setting_type = "runtime-per-user",
    default_value = 10,
    minimum_value = 1,
    maximum_value = 50,
    order = "a"
  },
  {
    type = "bool-setting",
    name = "scv-show-path",
    setting_type = "runtime-per-user",
    default_value = true,
    order = "b"
  }
})
