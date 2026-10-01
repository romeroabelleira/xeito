# Functions allowed above the CRAP maximum for now (Xeito.Crap). This list may only shrink:
# a function may not get worse, and an entry must go once its function is at or under the
# maximum. Add tests or simplify, then remove the entry.
%{
  "Mix.Tasks.Xeito.Chat.send_line/4" => 42.0,
  "Mix.Tasks.Xeito.Log.dispatch/4" => 42.0,
  "Mix.Tasks.Xeito.Log.prune/3" => 42.0,
  "Mix.Tasks.Xeito.Log.verify/1" => 42.0,
  "Xeito.Api.Connection.handle/3" => 116.3,
  "Xeito.Client.Render.render/2" => 215.9,
  "Xeito.Decision.Eval.predict/7" => 72.0,
  "Xeito.Effects.Local.run/2" => 43.8,
  "Xeito.Session.command/3" => 153.4,
  "Xeito.Session.step/2" => 42.0,
  "Xeito.Tui.event_to_msg/2" => 210.0,
  "Xeito.Tui.handle_info/2" => 35.8,
  "Xeito.Tui.handle_update/2" => 240.0,
  "Xeito.Tui.status_line/1" => 56.0,
  "Xeito.Tui.statusbar/2" => 156.0,
  "Xeito.Tui.track/3" => 37.2
}
