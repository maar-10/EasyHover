--[[ ui_main entry point.

     Launched by /startup.lua via shell.run -- never copied, so editing this file actually
     changes what runs. shell.run also matters because CC only injects `require`/`package` into
     shell-run programs, and the path below could not be set under dofile.

     "/?.lua" is what lets `require("shared.util")` and `require("basalt")` resolve: shared code
     installs at /shared/ and the vendored Basalt full build at /basalt.lua.
]]

package.path = "/ui_main/?.lua;/ui_main/?/init.lua;/?.lua;/?/init.lua;" .. package.path

local App = require("app")

local app = App.new({ echo = false })

app:run()
