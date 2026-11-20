-- Mocked UI/state checks; no Bluetooth or Noctalia session is touched.
local root = assert(arg[1]) .. "/"
local current
local rendered
local text
local icon
local tooltip
local modeIcons = 0
noctalia = {
 state = {get=function() return current end, watch=function() end, set=function() end},
 getConfig=function() return nil end, tr=function(k) return k end,
 isDarkMode=function() return true end, pluginDir=function() return '.' end,
 nowMs=function() return 1 end, setUpdateInterval=function() end,
}
ui = setmetatable({}, {__index=function(_, kind) return function(props, children)
 return {kind=kind, props=props, children=children}
end end})
panel = {render=function(tree) rendered=tree end}
desktopWidget = {render=function(tree) rendered=tree end}
barWidget = {setVisible=function() end, setImage=function(p) icon=p end,
 setText=function(t) text=t end, setTooltip=function(t) tooltip=t end,
 isVertical=function() return false end}
local realRequire=require
require=function(name)
 if name=='./shared.luau' then return dofile(root..'shared.luau') end
 if name=='./bar-icon.luau' then return dofile(root..'bar-icon.luau') end
 return realRequire(name)
end
local function inspect(tree, images, labels)
 if not tree then return end
 if tree.kind=='image' and not tree.props.path:find('icons/mode%-') then table.insert(images, tree.props.path) end
 if tree.kind=='image' and tree.props.path:find('icons/mode%-') then modeIcons = modeIcons + 1 end
 if tree.kind=='button' and tree.props.text then table.insert(labels, tree.props.text) end
 if tree.kind=='label' then table.insert(labels, tree.props.text) end
 for _, child in ipairs(tree.children or {}) do inspect(child, images, labels) end
end
for _, single in ipairs({true,false}) do
 current={connected=true, model={name='CMF Headphone Pro', battery_single=single, eq_presets={}},
  battery=single and {single={level=80,charging=true}} or {left={level=90},right={level=85}}, anc={mode='anc'}}
 for _, file in ipairs({'panel.luau','desktop-widget.luau'}) do
  dofile(root..file)
  local images, labels={},{}
  inspect(rendered, images, labels)
  assert(#images==(single and 1 or 3), file..': battery column count')
  if single then
   assert(images[1]=='icons/headphones.svg', file..': headphone image')
   assert(table.concat(labels,','):find('80%%'), file..': battery percentage')
   assert(not table.concat(labels,','):find('caption_auto'), file..': auto mono caption')
  end
 end
 dofile(root..'widget.luau')
 assert(text==(single and '80%' or '85%'), 'bar percentage')
 if single then assert(icon:find('bar%-headphones%-anc.svg'), 'bar headphone icon') end
end
assert(modeIcons==12, 'three noise-mode icons per panel and desktop render')
print('Panel, desktop and bar render correctly for headphones and earbuds')

local function findKey(tree, key)
 if not tree then return nil end
 if tree.props and tree.props.key==key then return tree end
 for _, child in ipairs(tree.children or {}) do
  local hit=findKey(child, key)
  if hit then return hit end
 end
end
-- Headphone-only controls: shown when the read answered, codec needs a confirm.
-- Main holds battery, noise control and presets; the rest is on the More tab.
local function panelText(state, tab)
 current=state
 dofile(root..'panel.luau')
 if tab=='more' then findKey(rendered,'tab-more').props.onClick() end
 local images, labels={},{}
 inspect(rendered, images, labels)
 return table.concat(labels,',')
end
local hp={connected=true, battery={single={level=80}}, anc={mode='off'},
 model={name='CMF Headphone Pro', battery_single=true, eq_presets={{index=3,name='pop'}},
  spatial={'concert','cinema','off'}, codecs={'aac','ldac'}}, eq_preset=3, spatial='concert', codec='aac'}
local shown=panelText(hp)
assert(shown:find('panel.eq.pop',1,true) and shown:find('panel.noise_control',1,true), 'main tab: presets and noise control')
assert(not shown:find('panel.spatial.title',1,true) and not shown:find('panel.codec.title',1,true), 'main tab stays short')
shown=panelText(hp, 'more')
assert(not shown:find('panel.eq.pop',1,true), 'more tab has no presets')
assert(shown:find('panel.spatial.cinema',1,true), 'spatial audio modes')
assert(findKey(rendered,'spatial-concert').children[1].props.path=='icons/spatial-concert.svg', 'spatial icon')
assert(shown:find('panel.codec.ldac',1,true) and shown:find('panel.codec.caption',1,true), 'codec row')
assert(not shown:find('panel.bass.title',1,true), 'no bass boost on headphones')
-- One click only arms the switch; the command goes out on Restart.
local sentCommand
noctalia.state.set=function(_, value) sentCommand=value end
findKey(rendered,'codec-aac').props.onClick()
assert(findKey(rendered,'codec-confirm')==nil and sentCommand==nil, 'current codec is not re-sent')
findKey(rendered,'codec-ldac').props.onClick()
assert(sentCommand==nil, 'codec switch waits for confirmation')
findKey(rendered,'codec-cancel').props.onClick()
assert(findKey(rendered,'codec-ldac') and sentCommand==nil, 'cancel restores the choice')
findKey(rendered,'codec-ldac').props.onClick()
findKey(rendered,'codec-confirm').props.onClick()
assert(sentCommand.action=='set-codec' and sentCommand.value=='ldac', 'confirmed codec switch is sent')
noctalia.state.set=function() end
hp.restarting=true
shown=panelText(hp, 'more')
assert(shown:find('panel.codec.restarting',1,true) and not shown:find('panel.codec.ldac',1,true), 'restarting hides codec buttons')
hp.restarting=false hp.spatial=nil hp.codec=nil
shown=panelText(hp, 'more')
assert(not shown:find('panel.spatial.title',1,true) and not shown:find('panel.codec.title',1,true), 'unanswered reads stay hidden')
assert(not panelText({connected=false}):find('panel.tab',1,true), 'no tabs while disconnected')
print('Headphone panel: Main/More tabs; spatial audio and codec shown only when readable; no bass boost')

-- Custom EQ sliders: on Main under the presets, only with Custom selected.
hp.spatial='concert' hp.codec='aac' hp.model.custom_eq=6
hp.model.eq_presets={{index=3,name='pop'},{index=6,name='custom'}}
hp.custom_eq={bass=2,mid=0,treble=-3}
panelText(hp)
assert(findKey(rendered,'custom-bass')==nil, 'no sliders on another preset')
hp.eq_preset=6
panelText(hp, 'more')
assert(findKey(rendered,'custom-bass')==nil, 'no sliders on the more tab')
shown=panelText(hp)
assert(findKey(rendered,'custom-treble').props.value==-3, 'slider shows the read curve')
assert(shown:find('+2 dB',1,true), 'signed gain label')
noctalia.state.set=function(_, value) sentCommand=value end
findKey(rendered,'custom-mid').props.onChange('4')
assert(sentCommand.action=='set-custom-eq' and sentCommand.value=='2,4,-3', 'slider sends the whole curve')
assert(findKey(rendered,'custom-mid').props.value==4, 'slider keeps the dragged value until read back')
sentCommand=nil
findKey(rendered,'custom-mid').props.onChange('4.2')
assert(sentCommand==nil, 'same step is not re-sent')
noctalia.state.set=function() end
hp.custom_eq=nil
assert(not panelText(hp):find('panel.custom_eq',1,true), 'unread curve hides sliders')
hp.write_error='busy'
assert(panelText(hp):find('panel.write_failed',1,true), 'failed write is shown')
hp.write_error=nil
print('Custom EQ: sliders under the presets while Custom is selected; failed writes shown')

-- Hide when disconnected: only with the setting on, and not during a restart.
local visible
barWidget.setVisible=function(v) visible=v end
local hide=false
noctalia.getConfig=function(key) if key=='hide_when_disconnected' then return hide end return nil end
for _, case in ipairs({
 {false, {connected=false}, true}, {true, {connected=false}, false}, {true, {unconfigured=true}, false},
 {true, {connected=false, restarting=true}, true}, {true, hp, true},
}) do
 hide=case[1] current=case[2]
 dofile(root..'widget.luau')
 assert(visible==case[3], 'bar visibility')
end
noctalia.getConfig=function() return nil end
print('Bar icon hides while disconnected only when asked to')

-- Bar icon color: follows the bar's icon color settings by tinting a copy of
-- the dark icon; unknown colors fall back to the plain icon.
local files, writes = {}, 0
local settings
local palette={on_surface='#e6e1e5', surface='#141218', surface_container='#211f26', primary='#d0bcff'}
noctalia.getSetting=function(path) return settings[path] end
noctalia.getColor=function(role) return palette[role] end
noctalia.pluginDataDir=function() return '/data' end
local repo=assert(arg[0]:match('^(.*)/tests/[^/]+$'))
noctalia.pluginDir=function() return repo end
noctalia.mkdirAll=function() return true end
noctalia.listDir=function() local out={} for k in pairs(files) do table.insert(out, k:match('[^/]+$')) end return out end
noctalia.removeFile=function(path) files[path]=nil return true end
noctalia.fileExists=function(path) return files[path]~=nil end
noctalia.readFile=function(path) local f=io.open(path) if not f then return nil end local t=f:read('*a') f:close() return t end
noctalia.writeFile=function(path, text) files[path]=text writes=writes+1 return true end
local function barIconFor(widgetEntry, bar, groupFg, state)
 bar.order=nil
 settings={bar={order={'main'}, main=bar}, widget={ne=widgetEntry}}
 if groupFg then
  bar['end']={'group:g'} bar.capsule_group={{id='g', members={'ne'}, foreground=groupFg}}
 else
  bar['end']={'ne'}
 end
 current=state or hp
 dofile(root..'widget.luau')
 return icon, files[icon]
end
local path, svg=barIconFor({type='zyrex/nothing-ear:nothing-ear', icon_color='#ff8800'}, {color='primary'})
assert(path:find('^/data/bar%-icons/bar%-headphones%-off%-FF8800%-141218%.svg$'), 'tinted icon path: '..path)
assert(svg:find('#FF8800',1,true) and not svg:find('#E6E1E5',1,true), 'widget icon_color tints the lines')
path, svg=barIconFor({type='zyrex/nothing-ear:nothing-ear'}, {color='primary'})
assert(svg:find('#D0BCFF',1,true), 'bar color used without icon_color')
assert(not files['/data/bar-icons/bar-headphones-off-FF8800-141218.svg'], 'old tint removed')
path, svg=barIconFor({type='zyrex/nothing-ear:nothing-ear'}, {icon_color='primary'}, '#123')
assert(svg:find('#112233',1,true) and path:find('211F26'), 'capsule group foreground and fill win')
local buds={connected=true, model={name='Ear (2)'}, battery={left={level=90}, right={level=85}}, anc={mode='anc'}}
path, svg=barIconFor({type='zyrex/nothing-ear:nothing-ear'}, {icon_color='#141218'}, nil, buds)
assert(path:find('bar%-pair%-anc') and svg:find('stroke="#141218"',1,true), 'earbuds icon tinted')
assert(svg:find('#D71921',1,true) and svg:find('#FFFFFF',1,true), 'red and white accents kept')
assert(select(2, svg:gsub('#141218',''))==3, 'one-pass swap: lines and knockout both 141218, nothing swapped twice')
path=barIconFor({type='zyrex/nothing-ear:nothing-ear', icon_color='no_such_role'}, {})
assert(path:find('icons/bar%-headphones%-off%.svg$'), 'unknown role falls back to the plain icon')
local before=writes
barIconFor({type='zyrex/nothing-ear:nothing-ear'}, {})
update()
assert(writes==before+1, 'update() only redraws when the color changes')
palette.on_surface='#000000'
update()
assert(icon:find('000000'), 'palette change picked up by update()')
noctalia.getSetting=nil noctalia.getColor=nil
print('Bar icon follows the bar icon color, falls back to plain icons')

local service = assert(io.open(root .. 'service.luau')):read('*a')
local beginAt = assert(service:find('local function singleBudOut', 1, true))
local endAt = assert(service:find('local function pollStatus', beginAt, true))
local env = setmetatable({
 monoAutoSetting=function() return true end,
 MONO_DEBOUNCE_POLLS=2, monoTriggerPolls=0, monoClearPolls=0,
 monoAutoSuppressed=false, monoActive=false, monoActivatedByAuto=false,
}, {__index=_G})
env.setMono = function(enabled, viaAuto)
 env.monoActive=enabled
 env.monoActivatedByAuto=enabled and viaAuto
end
local chunk = service:sub(beginAt, endAt - 1) .. '\nreturn evaluateMonoAuto'
local evaluateMonoAuto = assert(load(chunk, 'mono', 't', env))()
local one = {left={level=80}}
evaluateMonoAuto(one, {})
evaluateMonoAuto(one, {})
assert(env.monoActive, 'earbud auto mono regression')
evaluateMonoAuto(one, {battery_single=true})
evaluateMonoAuto(one, {battery_single=true})
assert(not env.monoActive, 'headphone transition must clear automatic mono')
for i=1,4 do evaluateMonoAuto({single={level=80}}, {}) end
assert(not env.monoActive, 'single battery must never trigger auto mono')
print('Auto mono: earbuds trigger; headphones never trigger and clear prior automatic mono')

-- Custom EQ writes from a slider drag: one at a time, only the latest queued.
local svc = assert(io.open(root .. 'service.luau')):read('*a')
local from = assert(svc:find('local function setCustomEq', 1, true))
local to = assert(svc:find('local function cycleAnc', from, true))
local runs, finish = {}, nil
local senv = setmetatable({
 customEqBusy=false, customEqQueued=nil,
 runCtl=function(args, cb) table.insert(runs, args[2]) finish=cb end,
 noteWrite=function() end, applyResultThenRefresh=function() end,
}, {__index=_G})
local setCustomEq = assert(load(svc:sub(from, to - 1) .. '\nreturn setCustomEq', 'eq', 't', senv))()
setCustomEq('1,0,0') setCustomEq('2,0,0') setCustomEq('3,0,0') setCustomEq('bad')
assert(#runs==1, 'one write in flight')
finish({ok=true})
assert(#runs==2 and runs[2]=='3,0,0', 'only the latest queued curve follows')
finish({ok=true})
assert(#runs==2 and not senv.customEqBusy, 'idle once caught up')
print('Custom EQ writes coalesce while one is in flight')
