function run_in_terminal(cmd::AbstractString)
    if OS_NAME == :Darwin
        open(`osascript`, "w") do p
            write(p, """
            tell application "System Events" to set ProcessList to get name of every process
            tell application "Terminal"
              activate
              do script ("exec $cmd")
            end tell
            """)
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
