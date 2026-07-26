--[[ EasyHover launcher -- installed as /startup.lua on a flight computer.

     It LAUNCHES the role's entry point. It is deliberately not a copy of it: DriveByWire's
     first installer copied the entry file's contents to /startup.lua, so editing the real
     entry file changed nothing and a stale copy ran instead. That cost an evening.

     shell.run, not dofile: CC only injects `require`/`package` into shell-run programs, and
     flight/startup.lua needs package.path to resolve its modules.
]]

shell.run("/flight/startup.lua")
