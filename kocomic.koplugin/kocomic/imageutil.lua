--[[--
图像底层操作:解码、缩放、拼版、取样、存 JPEG。

全部走 KOReader 自带的那套(turbojpeg 解码成 8 位灰度、mupdf 缩放),
灰度对水墨屏来说是无损的,还省一半内存。

这一层是唯一碰 FFI 的地方,排版逻辑全在 pager.lua 里 ——
所以在电脑上测的时候,把这一层换成 Pillow 实现,上面那层就能原样跑。
]]

local Blitbuffer = require("ffi/blitbuffer")
local Jpeg = require("ffi/jpeg")
local RenderImage = require("ui/renderimage")
local ffi = require("ffi")
local logger = require("logger")

-- turbojpeg 的枚举值(ffi/turbojpeg_h.lua 里定义的,这里直接用数值免得再 loadlib)
local TJPF_RGB, TJPF_GRAY = 0, 6
local TJSAMP_420, TJSAMP_GRAY = 2, 3

local ImageUtil = {}

-- —————————————— 解码 ——————————————

--- 解码成 BlitBuffer,scale_w 给了就顺便缩放到这个宽度(高度按比例)。
function ImageUtil.decode(data, scale_w)
    if type(data) ~= "string" or #data == 0 then
        return nil, "空图片"
    end
    local ok, bb = pcall(function()
        return RenderImage:renderImageData(data, #data, false)
    end)
    if not ok or not bb then
        return nil, "解码失败"
    end
    if scale_w and bb:getWidth() ~= scale_w then
        local height = math.max(1, math.floor(bb:getHeight() * scale_w / bb:getWidth() + 0.5))
        local scaled = RenderImage:scaleBlitBuffer(bb, scale_w, height, true)
        if not scaled then
            return nil, "缩放失败"
        end
        return scaled
    end
    return bb
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

--- 缩到指定尺寸。默认不动来源(要不要释放由调用方自己决定)。
function ImageUtil.scaleTo(bb, width, height, free_source)
    local scaled = RenderImage:scaleBlitBuffer(bb, width, height, free_source == true)
    return scaled or bb
end

--- 按比例缩到能塞进 max_w × max_h 的最大尺寸(不放大)
function ImageUtil.fitInto(bb, max_w, max_h)
    local w, h = bb:getWidth(), bb:getHeight()
    local scale = math.min(max_w / w, max_h / h)
    if scale >= 1 then
        return bb
    end
    local new_w = math.max(1, math.floor(w * scale + 0.5))
    local new_h = math.max(1, math.floor(h * scale + 0.5))
    return RenderImage:scaleBlitBuffer(bb, new_w, new_h, true) or bb
end

-- —————————————— 拼版 ——————————————

--- 新建一张白底的页
function ImageUtil.newPage(width, height, bb_type)
    local page = Blitbuffer.new(width, height, bb_type or Blitbuffer.TYPE_BB8)
    page:fill(Blitbuffer.COLOR_WHITE)
    return page
end

function ImageUtil.blit(page, source, dest_x, dest_y, src_x, src_y, width, height)
    page:blitFrom(source, dest_x, dest_y, src_x, src_y, width, height)
end

function ImageUtil.whiteOut(page, x, y, width, height)
    if height > 0 and width > 0 then
        page:paintRect(x, y, width, height, Blitbuffer.COLOR_WHITE)
    end
end

--- 画一条淡淡的分隔线
function ImageUtil.drawRule(page, x, y, width, height)
    page:paintRect(x, y, width, height or 1, Blitbuffer.COLOR_GRAY)
end

function ImageUtil.free(bb)
    if bb and bb.free then
        bb:free()
    end
end

function ImageUtil.size(bb)
    return bb:getWidth(), bb:getHeight()
end

-- —————————————— 取样 ——————————————

--- 这一行有多少「墨」(0 = 全白,1 = 全黑)。抽样看,不用每个像素都数。
--- pager 靠它找空白横线来决定在哪切页。
function ImageUtil.rowInk(bb, y, step)
    step = step or 8
    local width = bb:getWidth()
    local bb_type = bb:getType()
    local bytes = ffi.cast("uint8_t*", bb.data)
    local row = tonumber(bb.stride) * y
    local pixel_bytes = 1
    if bb_type == Blitbuffer.TYPE_BBRGB24 then
        pixel_bytes = 3
    elseif bb_type == Blitbuffer.TYPE_BBRGB32 then
        pixel_bytes = 4
    elseif bb_type == Blitbuffer.TYPE_BB8A then
        pixel_bytes = 2
    elseif bb_type ~= Blitbuffer.TYPE_BB8 then
        return 1    -- 4 位或 16 位的少见格式,不猜了,当成有内容
    end
    local dark, total = 0, 0
    for x = 0, width - 1, step do
        if bytes[row + x * pixel_bytes] < 224 then
            dark = dark + 1
        end
        total = total + 1
    end
    if total == 0 then
        return 0
    end
    return dark / total
end

--- 沿着一行等距取 count 个灰度值,给 pager 判断两张碎图是不是接得上。
function ImageUtil.rowSample(bb, y, count)
    count = count or 64
    local width = bb:getWidth()
    local bb_type = bb:getType()
    local bytes = ffi.cast("uint8_t*", bb.data)
    local row = tonumber(bb.stride) * math.max(0, math.min(y, bb:getHeight() - 1))
    local pixel_bytes = 1
    if bb_type == Blitbuffer.TYPE_BBRGB24 then
        pixel_bytes = 3
    elseif bb_type == Blitbuffer.TYPE_BBRGB32 then
        pixel_bytes = 4
    elseif bb_type == Blitbuffer.TYPE_BB8A then
        pixel_bytes = 2
    elseif bb_type ~= Blitbuffer.TYPE_BB8 then
        return nil
    end
    local values = {}
    for i = 0, count - 1 do
        local x = math.floor(i * (width - 1) / math.max(1, count - 1))
        values[i + 1] = bytes[row + x * pixel_bytes]
    end
    return values
end

-- —————————————— 直方图与映射 ——————————————

local function pixelBytesOf(bb)
    local bb_type = bb:getType()
    if bb_type == Blitbuffer.TYPE_BB8 then
        return 1
    elseif bb_type == Blitbuffer.TYPE_BB8A then
        return 2
    elseif bb_type == Blitbuffer.TYPE_BBRGB24 then
        return 3
    elseif bb_type == Blitbuffer.TYPE_BBRGB32 then
        return 4
    end
    return nil
end

--- 数一遍灰度分布(抽样,step 是隔几个像素取一个),给 levels.lua 算映射表用。
function ImageUtil.histogram(bb, step)
    local pixel_bytes = pixelBytesOf(bb)
    if not pixel_bytes then
        return nil
    end
    step = step or 4
    local width, height = bb:getWidth(), bb:getHeight()
    local stride = tonumber(bb.stride)
    local bytes = ffi.cast("uint8_t*", bb.data)
    local histogram = {}
    for i = 1, 256 do
        histogram[i] = 0
    end
    for y = 0, height - 1, step do
        local row = stride * y
        for x = 0, width - 1, step do
            local value = bytes[row + x * pixel_bytes]
            histogram[value + 1] = histogram[value + 1] + 1
        end
    end
    return histogram
end

--- 把 256 项映射表套到整张图上(原地改)。
function ImageUtil.applyLut(bb, lut)
    local pixel_bytes = pixelBytesOf(bb)
    if not pixel_bytes or not lut then
        return false
    end
    local table_c = ffi.new("uint8_t[256]")
    for i = 0, 255 do
        table_c[i] = lut[i + 1] or i
    end
    local width, height = bb:getWidth(), bb:getHeight()
    local stride = tonumber(bb.stride)
    local bytes = ffi.cast("uint8_t*", bb.data)
    if pixel_bytes == 1 or pixel_bytes == 3 then
        -- 灰度和 RGB24 没有 alpha,一路平推(彩色三通道套同一张表 = 整体拉对比度)
        local span = width * pixel_bytes - 1
        for y = 0, height - 1 do
            local row = stride * y
            for x = 0, span do
                bytes[row + x] = table_c[bytes[row + x]]
            end
        end
    else
        -- 带 alpha 的格式,最后一个字节不能动
        for y = 0, height - 1 do
            local row = stride * y
            for x = 0, width - 1 do
                local base = row + x * pixel_bytes
                for channel = 0, pixel_bytes - 2 do
                    bytes[base + channel] = table_c[bytes[base + channel]]
                end
            end
        end
    end
    return true
end

-- —————————————— 存盘 ——————————————

--- 存成 JPEG。灰度图存灰度 JPEG(体积小一半),彩屏设备存彩色。
function ImageUtil.saveJpeg(bb, path, quality)
    local bb_type = bb:getType()
    local color_type, subsample
    local source = bb
    if bb_type == Blitbuffer.TYPE_BB8 then
        color_type, subsample = TJPF_GRAY, TJSAMP_GRAY
    elseif bb_type == Blitbuffer.TYPE_BBRGB24 then
        color_type, subsample = TJPF_RGB, TJSAMP_420
    else
        -- 其它格式先转成 8 位灰度再存
        source = Blitbuffer.new(bb:getWidth(), bb:getHeight(), Blitbuffer.TYPE_BB8)
        source:blitFrom(bb, 0, 0, 0, 0, bb:getWidth(), bb:getHeight())
        color_type, subsample = TJPF_GRAY, TJSAMP_GRAY
    end
    local ok, err = pcall(function()
        Jpeg.encodeToFile(path, ffi.cast("const unsigned char*", source.data),
            source:getWidth(), tonumber(source.stride), source:getHeight(),
            quality or 85, color_type, subsample)
    end)
    if source ~= bb then
        source:free()
    end
    if not ok then
        logger.warn("KoComic: 存 JPEG 失败", err)
        return nil, tostring(err)
    end
    return true
end

--- 存成 PNG。文字页(吐槽)用它:无损、比 JPEG 锐利,大片白底还更小。
function ImageUtil.savePng(bb, path)
    local ok, Png = pcall(require, "ffi/png")
    if not ok then
        return ImageUtil.saveJpeg(bb, path, 92)
    end
    local bb_type = bb:getType()
    local components = (bb_type == Blitbuffer.TYPE_BB8) and 1
        or (bb_type == Blitbuffer.TYPE_BBRGB24) and 3 or nil
    if not components then
        return ImageUtil.saveJpeg(bb, path, 92)
    end
    local written = pcall(function()
        Png.encodeToFile(path, ffi.cast("const unsigned char*", bb.data),
            bb:getWidth(), bb:getHeight(), components)
    end)
    if not written then
        logger.warn("KoComic: 存 PNG 失败,退回 JPEG")
        return ImageUtil.saveJpeg(bb, path, 92)
    end
    return true
end

return ImageUtil
