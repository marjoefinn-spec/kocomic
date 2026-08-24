--[[--
测试用的 imageutil:接口和真机那份一模一样,底下换成 Python 的 Pillow。

真机那份全是 FFI(BlitBuffer / turbojpeg / mupdf),在电脑上跑不了;
而排版逻辑(pager.lua)才是真正容易出错的地方,把这一层换掉之后
pager、downloader、reader 全都是原封不动的真代码。
]]

local PY = _G.PY

local ImageUtil = {}

local function wrap(id, width, height)
    return {
        id = id,
        width = width,
        height = height,
        getWidth = function(self) return self.width end,
        getHeight = function(self) return self.height end,
        getType = function() return 1 end,
        free = function(self) PY.img_free(self.id) end,
        paintRect = function(self, x, y, w, h) PY.img_white(self.id, x, y, w, h) end,
    }
end

function ImageUtil.decode(data, scale_w)
    local id, width, height = PY.img_decode(data, scale_w)
    if not id then
        return nil, "解码失败"
    end
    return wrap(id, width, height)
end

function ImageUtil.decodeFile(path, scale_w)
    local file = io.open(path, "rb")
    if not file then
        return nil, "打不开:" .. path
    end
    local data = file:read("*a")
    file:close()
    return ImageUtil.decode(data, scale_w)
end

function ImageUtil.scaleTo(bb, width, height)
    local id, w, h = PY.img_scale(bb.id, width, height)
    return wrap(id, w, h)
end

function ImageUtil.fitInto(bb, max_w, max_h)
    local scale = math.min(max_w / bb.width, max_h / bb.height)
    if scale >= 1 then
        return bb
    end
    return ImageUtil.scaleTo(bb, math.floor(bb.width * scale), math.floor(bb.height * scale))
end

function ImageUtil.newPage(width, height)
    local id = PY.img_new(width, height)
    return wrap(id, width, height)
end

function ImageUtil.blit(page, source, dest_x, dest_y, src_x, src_y, width, height)
    PY.img_blit(page.id, source.id, dest_x, dest_y, src_x, src_y, width, height)
end

function ImageUtil.whiteOut(page, x, y, width, height)
    if width > 0 and height > 0 then
        PY.img_white(page.id, x, y, width, height)
    end
end

function ImageUtil.drawRule(page, x, y, width, height)
    PY.img_fill(page.id, x, y, width, height or 1, 170)
end

function ImageUtil.free(bb)
    if bb and bb.id then
        PY.img_free(bb.id)
    end
end

function ImageUtil.size(bb)
    return bb.width, bb.height
end

function ImageUtil.rowInk(bb, y, step)
    return PY.img_row_ink(bb.id, y, step or 8)
end

function ImageUtil.rowSample(bb, y, count)
    return PY.img_row_sample(bb.id, y, count or 64)
end

function ImageUtil.histogram(bb, step)
    return PY.img_histogram(bb.id, step or 4)
end

function ImageUtil.applyLut(bb, lut)
    return PY.img_apply_lut(bb.id, lut)
end

function ImageUtil.saveJpeg(bb, path, quality)
    return PY.img_save(bb.id, path, quality or 85)
end

function ImageUtil.savePng(bb, path)
    return PY.img_save_png(bb.id, path)
end

return ImageUtil
