--[[ Navigation computer entry point.

     Launched by the installer's /startup.lua via shell.run -- never copied, so editing this
     file actually changes what runs.

     shell.run also matters for another reason: CC only injects `require`/`package` into
     shell-run programs. Under dofile, `package` is nil and the path below cannot be set.
]]

package.path = "/nav/?.lua;/nav/?/init.lua;/?.lua;/?/init.lua;" .. package.path

local App = require("app")
local app = App.new({ echo = false })
app:run()
