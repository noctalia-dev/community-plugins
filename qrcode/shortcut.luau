local function render()
    shortcut.setLabel("QR Code")
    shortcut.setIcon("qrcode")
end

render()

function onClick()
  noctalia.togglePanel("yocraft/qrcode:panel")
end
