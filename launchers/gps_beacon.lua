--[[ EasyHover launcher -- installed as /startup.lua on a gps_beacon computer.

     It LAUNCHES the role's entry point rather than duplicating it: a copied entry file means
     editing the real one changes nothing, and the Suite then has two files to keep in step.
]]

shell.run("/gps_beacon/startup.lua")
