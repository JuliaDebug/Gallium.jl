using TerminalUI
using Gallium
import TerminalUI: TightCentering, Widget, center

center(w::Widget) = TightCentering(w)
function prompt_connection(tty)
  local pidi
  d = FullScreenDialog(center(
    Border("New Connection",make_widget(
      [
        [ "PID", (pid = Query{Int}()) ]'
        #( newi = Button("New Instance") )
      ])
    )),tty)
    on_done(pid) do x
      pidi = x
      close(d)
    end
  wait(d)
  pidi
end

tty = Base.Terminals.TTYTerminal("xterm",STDIN,STDOUT,STDERR)
prompt_connection(tty)
