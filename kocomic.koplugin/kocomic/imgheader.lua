--[[--
只读文件头拿图片宽高,不解码。

判断这一话是条漫还是单页漫画要先知道每张图的长宽,几十张图全解一遍太亏,
读那几十个字节就够了。认不出来的格式返回 nil,调用方再去老老实实解码。

纯 Lua,不碰 FFI —— 所以在电脑上也能直接测。
]]

local ImgHeader = {}

function ImgHeader.imageSize(data)
    if type(data) ~= "string" or #data < 24 then
        return nil
    end
    local function be16(offset)
        return data:byte(offset) * 256 + data:byte(offset + 1)
    end
    local function be32(offset)
        return data:byte(offset) * 16777216 + data:byte(offset + 1) * 65536
            + data:byte(offset + 2) * 256 + data:byte(offset + 3)
    end

    if data:byte(1) == 0xFF and data:byte(2) == 0xD8 then          -- JPEG
        local i = 3
        while i < #data - 9 do
            if data:byte(i) ~= 0xFF then
                i = i + 1
            else
                local marker = data:byte(i + 1)
                if marker >= 0xC0 and marker <= 0xCF
                        and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
                    return be16(i + 7), be16(i + 5)                -- SOFn 里高在前宽在后
                elseif marker == 0xD8 or marker == 0xD9 or (marker >= 0xD0 and marker <= 0xD7) then
                    i = i + 2
                else
                    i = i + 2 + be16(i + 2)
                end
            end
        end
        return nil
    end

    if data:sub(1, 8) == "\137PNG\r\n\26\n" then                    -- PNG
        return be32(17), be32(21)
    end

    if data:sub(1, 4) == "GIF8" then                                -- GIF(小端)
        return data:byte(8) * 256 + data:byte(7), data:byte(10) * 256 + data:byte(9)
    end

    if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then  -- WebP
        local chunk = data:sub(13, 16)
        if chunk == "VP8X" then
            local function le24(offset)
                return data:byte(offset) + data:byte(offset + 1) * 256
                    + data:byte(offset + 2) * 65536
            end
            return le24(25) + 1, le24(28) + 1
        elseif chunk == "VP8 " and #data >= 30 then
            return (data:byte(27) + data:byte(28) * 256) % 16384,
                   (data:byte(29) + data:byte(30) * 256) % 16384
        end
        return nil
    end

    return nil
end

return ImgHeader
