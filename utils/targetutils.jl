function run_in_terminal(cmd::AbstractString)
    if OS_NAME == :Darwin
        open(`osascript`, "w") do p
            if !haskey(ENV,"TERM_PROGRAM") || ENV["TERM_PROGRAM"] == "Apple_Terminal"
                write(p, """
                tell application "System Events" to set ProcessList to get name of every process
                tell application "Terminal"
                  activate
                  do script ("exec $cmd")
                end tell
                """)
            elseif ENV["TERM_PROGRAM"] == "iTerm.app"
                write(p,"""
                tell application "System Events"
                    set appWasRunning to exists (processes where name is "iTerm")
                    tell application "iTerm"
                        set newWindow to (create window with default profile command "$cmd")
                    end tell
                end tell
                """)
            else
                error("Unkown terminal emulator `$(ENV["TERM_PROGRAM"])`")
            end
        end
    elseif isreadable("/etc/alternatives/x-terminal-emulator")
        spawn(`/etc/alternatives/x-terminal-emulator -e $cmd`)
    elseif OS_NAME == :Linux || OS_NAME == :FreeBSD
        spawn(`xterm -e $cmd`)
    else
        error("could not find terminal emulator")
    end
end

function gallium_cmd()
    script = joinpath(Pkg.dir(), "Gallium", "examples", "launch.jl")
    julia = joinpath(JULIA_HOME, "julia")
    "$julia -q $script $(getpid())"
end

gallium() = run_in_terminal(gallium_cmd())

"""
If a debugger is present, stop execution at this point.
If a debugger, is not present proceed as usual.
"""
breakpoint() = try
    ccall(:jl_raise_debugger, Int, ())
end
