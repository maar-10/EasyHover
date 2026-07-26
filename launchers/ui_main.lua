--[[ EasyHover launcher -- installed as /startup.lua on a ui_main computer.

     It LAUNCHES the role's entry point rather than duplicating it, for the same reason as the
     flight launcher: a copied entry file means editing the real one changes nothing.
]]

shell.run("/ui_main/startup.lua")
