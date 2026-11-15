--!nonstrict

function onActivate()
  if noctalia.getConfig("candidate_mode") == "best" then
    noctalia.notify(noctalia.tr("panel.best_mode_title"), noctalia.tr("panel.best_mode_body"))
    return
  end
  noctalia.togglePanel("h465855hgg/lyrics:selector")
end
