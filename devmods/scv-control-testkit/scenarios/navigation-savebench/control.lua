-- The real saved map is the corpus source. Behavior stays in the local TestKit
-- mod so loading a source save can test new implementations without embedding
-- algorithms or regenerating fixture geometry in this marker scenario.
remote.add_interface("scv_navigation_savebench", {active = function() return true end})
