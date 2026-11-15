-- Mocked UI/state checks; no Bluetooth or Noctalia session is touched.
local root = assert(arg[1]) .. "/"
local current
local rendered
local text
local icon
local tooltip
noctalia = {
 state = {get=function() return current end, watch=function() end, set=function() end},
 getConfig=function() return nil end, tr=function(k) return k end,
 isDarkMode=function() return true end, pluginDir=function() return '.' end,
 nowMs=function() return 1 end,
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
require=function(name) if name=='./shared.luau' then return dofile(root..'shared.luau') end return realRequire(name) end
local function inspect(tree, images, labels)
 if not tree then return end
 if tree.kind=='image' then table.insert(images, tree.props.path) end
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
print('Panel, desktop and bar render correctly for headphones and earbuds')

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
