function gallium()
open(`osascript`,"w") do p
     write(p,"""
     tell application "System Events"
         set appWasRunning to exists (processes where name is "iTerm")

         tell application "iTerm"
             set newWindow to (create window with default profile command "~/Projects/julia-testpatch/julia -q ~/.julia/Gallium/examples/launch.jl $(getpid())")
         end tell
     end tell
     """)
end
end
