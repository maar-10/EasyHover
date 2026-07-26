--[[ Flight computer entry point.

     Launched by the installer's /startup.lua via shell.run -- never copied, so editing this
     file actually changes what runs (DriveByWire installer lesson).

     shell.run also matters for another reason: CC only injects `require`/`package` into
     shell-run programs. Under dofile, `package` is nil and the path below cannot be set.
]]

package.path = "/flight/?.lua;/flight/?/init.lua;/?.lua;/?/init.lua;" .. package.path

local App = require("app")

local app = App.new({ echo = true })

print("EasyHover flight computer")
print("Hold Ctrl+T to stop. The hardware failsafe holds the craft if this program exits.")
print("")

app:run()
