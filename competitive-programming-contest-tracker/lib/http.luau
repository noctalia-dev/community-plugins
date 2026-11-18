--!nonstrict
local M = {}

local USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36"

function M.request(req: HttpRequest, cb: (body: string?) -> ())
  local headers: { string } = { USER_AGENT }
  for _, h in ipairs(req.headers or {}) do
    table.insert(headers, h)
  end
  req.headers = headers

  local accepted = noctalia.http(req, function(res: HttpResponse)
    if res.ok and res.status == 200 then
      cb(res.body)
    else
      cb(nil)
    end
  end)
  if not accepted then
    cb(nil)
  end
end

function M.getJson(req: HttpRequest, cb: (data: any) -> ())
  M.request(req, function(body: string?)
    if not body then
      return cb(nil)
    end
    return cb((noctalia.json.decode(body)))
  end)
end

return M
