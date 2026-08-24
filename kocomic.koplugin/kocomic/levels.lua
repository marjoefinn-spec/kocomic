--[[--
自动色阶:把一张图的黑白点拉到位。

扫描来的漫画常常「发灰」—— 纸不是纯白(比如 235),黑线也不是纯黑(比如 40),
整张图挤在中间那段灰里。水墨屏本来层次就少,这一挤就更糊。

做法是老一套的 levels:数一遍直方图,找出真正的黑点和白点(各留 0.5% 的余量
给噪点和网点),再把这一段重新拉满 0~255。比无脑调高对比度好在它是**按每张图
自适应**的 —— 本来就够黑的图不会被压死,发灰的图才会被拉开。

纯 Lua、无副作用:进来一个直方图,出去一张 256 项的映射表。
]]

local Levels = {}

--- 从直方图算出映射表。
-- @param histogram 256 项的计数表(1 号槽 = 灰度 0)
-- @param opts.clip_low   低端裁掉的比例,默认 0.005
-- @param opts.clip_high  高端裁掉的比例,默认 0.005
-- @param opts.min_range  黑白点至少要差这么多才动手,默认 24
-- @param opts.max_shift  黑白点最多各挪这么多,默认 96(防止把整张图拉爆)
-- @param opts.gamma      额外的伽马,>1 变暗,默认 1(不动)
-- @return 256 项映射表;不需要调整时返回 nil
function Levels.computeLut(histogram, opts)
    opts = opts or {}
    local clip_low = opts.clip_low or 0.005
    local clip_high = opts.clip_high or 0.005
    local min_range = opts.min_range or 24
    local max_shift = opts.max_shift or 96
    local gamma = opts.gamma or 1

    local total = 0
    for i = 1, 256 do
        total = total + (histogram[i] or 0)
    end
    if total == 0 then
        return nil
    end

    -- 找黑点:从暗端往上累,越过 clip_low 就停
    local black, white = 0, 255
    local threshold = total * clip_low
    local seen = 0
    for i = 1, 256 do
        seen = seen + (histogram[i] or 0)
        if seen > threshold then
            black = i - 1
            break
        end
    end
    threshold = total * clip_high
    seen = 0
    for i = 256, 1, -1 do
        seen = seen + (histogram[i] or 0)
        if seen > threshold then
            white = i - 1
            break
        end
    end

    -- 只拉「有证据」的那一边,免得把作者故意画暗/画淡的页面改坏:
    -- 找不到纸白,说明这页本来就暗(全黑跨页、夜景),就别硬提亮
    if white < 255 - max_shift then
        white = 255
    end
    -- 找不到真黑,说明这页本来就淡(留白页、彩页),就别硬压黑
    if black > max_shift then
        black = 0
    end
    if white - black < min_range then
        return nil
    end
    if black <= 4 and white >= 250 and gamma == 1 then
        return nil    -- 已经差不多拉满了,不折腾
    end

    local lut = {}
    local scale = 255 / (white - black)
    for value = 0, 255 do
        local mapped = (value - black) * scale
        if mapped < 0 then
            mapped = 0
        elseif mapped > 255 then
            mapped = 255
        end
        if gamma ~= 1 then
            mapped = 255 * (mapped / 255) ^ gamma
        end
        lut[value + 1] = math.floor(mapped + 0.5)
    end
    return lut, black, white
end

--- 只做伽马、不动黑白点。给在线阅读器用:
--- 下载下来的书是 KOReader 在渲染时套伽马(kopt_contrast),
--- 在线阅读绕开了 KOReader 的文档管线,得自己套一遍,两边看起来才一致。
function Levels.gammaLut(gamma)
    if not gamma or gamma == 1 then
        return nil
    end
    local lut = {}
    for value = 0, 255 do
        lut[value + 1] = math.floor(255 * (value / 255) ^ gamma + 0.5)
    end
    return lut
end

return Levels
