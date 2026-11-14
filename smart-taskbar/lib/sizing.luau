--!nonstrict
-- Public configuration only; no guessed runtime geometry or polling.
local M={}
local TYPE="omardardery/smart-taskbar:taskbar"
local function number(value,default,low,high)
  if type(value)~="number" or value~=value then return default end
  return math.clamp(value,low,high)
end
local function placements(bar,widgets)
  local result={}
  local function add(name,grouped)
    local widget=widgets[name]
    if name==TYPE or (type(widget)=="table" and widget.type==TYPE) then
      if type(widget)~="table" then widget={} end
      if widget.enabled~=false then table.insert(result,{widget=widget,grouped=grouped}) end
    end
  end
  for _,lane in ipairs({"start","center","end"}) do
    for _,name in ipairs(type(bar[lane])=="table" and bar[lane] or {}) do
      if type(name)=="string" and string.sub(name,1,6)=="group:" then
        for _,group in ipairs(type(bar.capsule_group)=="table" and bar.capsule_group or {}) do
          if group.id==string.sub(name,7) and group.enabled~=false then
            for _,member in ipairs(group.members or {}) do add(member,true) end
          end
        end
      elseif type(name)=="string" then add(name,false) end
    end
  end
  return result
end
function M.resolve(c,bars,widgets,output,vertical,outputs)
  if c.sizing_mode~="auto" or type(bars)~="table" or type(widgets)~="table" then return c end
  local description=""
  for _,item in ipairs(outputs or {}) do if item.name==output then description=item.description or "" end end
  local cross,scale,padding,textScale=nil,0,0,0
  local function consider(bar)
    if bar.enabled==false then return end
    local side=bar.position=="left" or bar.position=="right"
    if side~=vertical then return end
    for _,placement in ipairs(placements(bar,widgets)) do
      local w=placement.widget
      local contentScale=number(bar.scale,1,0.2,2.5)*number(w.scale,1,0.2,2.5)
      local capsule=w.capsule
      if capsule==nil then capsule=bar.capsule end
      local thickness=math.max(1,number(bar.thickness,34,1,512)-2*number(bar.border_width,0,0,8))
      if capsule or placement.grouped then thickness=math.max(1,math.floor(thickness*number(bar.capsule_thickness,0.76,0.1,1)+0.5)) end
      -- Leave two logical pixels of clearance on either side of the host surface.
      local available=math.max(1,(thickness-4)/contentScale)
      cross=cross and math.min(cross,available) or available
      scale=math.max(scale,contentScale)
      textScale=math.max(textScale,number(bar.font_scale,1,0.2,2.5)*number(w.font_scale,1,0.2,2.5))
      if capsule and not placement.grouped then
        padding=math.max(padding,number(w.capsule_padding,number(bar.capsule_padding,6,0,48),0,48))
      end
    end
  end
  for name,base in pairs(bars) do
    if type(base)=="table" and (c.sizing_bar=="" or c.sizing_bar==name) then
      local matched=false
      for key,override in pairs(type(base.monitor)=="table" and base.monitor or {}) do
        if type(override)=="table" then
          local match=override.match or key
          if type(match)=="string" and match~="" and (match==output or string.find(description,match,1,true)) then
            local effective=table.clone(base)
            for field,value in pairs(override) do effective[field]=value end
            consider(effective); matched=true
          end
        end
      end
      -- Luau tables do not expose TOML source order. If multiple overrides match,
      -- fit every possible first-match result rather than guessing their order.
      if not matched then consider(base) end
    end
  end
  if not cross then return c end
  cross=math.max(1,math.floor(cross))
  local result=table.clone(c)
  result.cell_padding=math.min(4,math.max(0,math.floor((cross-1)/4)))
  local factor=c.hover_enlarge and math.min(c.hover_scale,math.max(1,cross-2*result.cell_padding)) or 1
  if c.hover_enlarge then result.hover_scale=factor end
  result.icon_size=math.clamp(math.floor((cross-2*result.cell_padding)/factor),1,64)
  result.icon_spacing=math.clamp(math.floor(result.icon_size/6),2,8)
  result.capsule_radius=(math.ceil(result.icon_size*factor)+2*result.cell_padding)/2
  result.max_width=math.max(1,math.floor(c.max_width/scale-2*padding))
  result.min_width=math.min(result.max_width,math.ceil(result.icon_size*factor)+2*result.cell_padding+16)
  result.collapsed_width=math.min(result.max_width,result.min_width)
  if c.collapsed_label=="count" then result.collapsed_width=math.min(result.max_width,result.min_width+20)
  elseif c.collapsed_label~="none" then result.collapsed_width=math.min(result.max_width,result.min_width+2*result.icon_size) end
  result.auto_text_scale=textScale
  result.auto_sized=true
  return result
end
return M
