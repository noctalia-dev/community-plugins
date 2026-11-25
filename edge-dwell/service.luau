--!nonstrict
noctalia.setUpdateInterval(100)

local started = false
function update()
    if started then
        return
    end
    started = true
    noctalia.layer.show("left")
    noctalia.layer.show("right")
    noctalia.setUpdateInterval(86400000)
end
