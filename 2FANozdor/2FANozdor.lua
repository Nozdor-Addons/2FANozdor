-- TWOFANozdor.lua
-- Аддон для захвата 2FA ключа, отображения его в EditBox и генерации QR-кода.

-- WoW API globals
-- luacheck: globals CreateFrame UIParent UnitName GetRealmName DEFAULT_CHAT_FRAME ChatFrame1 ChatEdit_SendText SendChatMessage SlashCmdList
-- luacheck: globals TWOFANozdorFrame TWOFANozdorEditBox

-- Храним последний ключ и последнюю QR-матрицу
TWOFANozdor_LastKey = nil
TWOFANozdor_LastQR  = nil

------------------------------------------------------
-- Проверка наличия библиотеки qrencode
------------------------------------------------------

local function TWOFANozdor_CheckQRLib()
    if type(qrencode) ~= "table" or type(qrencode.qrcode) ~= "function" then
        return false
    end
    return true
end

------------------------------------------------------
-- Функция URL-энкодинга для otpauth://
------------------------------------------------------

local function TWOFANozdor_UrlEncode(str)
    if not str then
        return ""
    end
    -- Кодируем всё, кроме: буквы/цифры, '_', '.', '-', '~', ':'
    str = string.gsub(str, "([^%w_%.%-%~:])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    return str
end

------------------------------------------------------
-- Формирование otpauth:// URL для TOTP
------------------------------------------------------

local function TWOFANozdor_BuildTOTPUrl(secret)
    local playerName = UnitName and UnitName("player") or "Player"
    local realmName  = GetRealmName and GetRealmName() or "Realm"
    local issuer     = "Nozdor"

    local label = issuer .. ":" .. playerName .. "@" .. realmName

    local encLabel  = TWOFANozdor_UrlEncode(label)
    local encSecret = TWOFANozdor_UrlEncode(secret or "")
    local encIssuer = TWOFANozdor_UrlEncode(issuer)

    local url = "otpauth://totp/" .. encLabel
        .. "?secret=" .. encSecret
        .. "&issuer=" .. encIssuer
        .. "&digits=6&period=30&algorithm=SHA1"

    return url
end

------------------------------------------------------
-- Окно с EditBox + QR
------------------------------------------------------

local function TWOFANozdor_CreateFrame()
    if TWOFANozdorFrame then
        return
    end

    local f = CreateFrame("Frame", "TWOFANozdorFrame", UIParent)
    -- Окно компактного размера с центрированными элементами
    f:SetSize(350, 450)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    -- Используем стиль панели персонажа (Tooltip style)
    f:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile     = true,
        tileSize = 16,
        edgeSize = 16,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.08, 0.05, 0.04, 1.0)   -- очень тёмно-коричневый фон без прозрачности
    f:SetBackdropBorderColor(0.4, 0.3, 0.25, 1)  -- коричневая рамка в стиле персонажа

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -10)
    title:SetText("|cffff0000Управление 2FA|r")

    local desc = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    desc:SetPoint("TOP", title, "BOTTOM", 0, -4)
    desc:SetText("Скопируйте ключ (Ctrl+C) или отсканируйте QR-код ниже.")

    local editBox = CreateFrame("EditBox", "TWOFANozdorEditBox", f, "InputBoxTemplate")
    editBox:SetAutoFocus(true)
    editBox:SetSize(280, 24)
    editBox:SetPoint("TOP", desc, "BOTTOM", 0, -6)
    editBox:SetPoint("LEFT", f, "LEFT", 35, 0) -- Центрируем (350 - 280) / 2 = 35
    editBox:SetMaxLetters(128)
    editBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        self:GetParent():Hide()
    end)

    local qrLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    qrLabel:SetPoint("TOP", editBox, "BOTTOM", 0, -6)
    qrLabel:SetText("QR-код для приложения-аутентификатора:")

    --------------------------------------------------
    -- Белая «карточка» под QR (уменьшенная и по центру)
    --------------------------------------------------
    local qrCard = CreateFrame("Frame", "TWOFANozdorQRCard", f)
    qrCard:SetSize(250, 250)
    qrCard:SetPoint("TOP", qrLabel, "BOTTOM", 0, -6)
    qrCard:SetPoint("LEFT", f, "LEFT", 50, 0) -- Центрируем (350 - 250) / 2 = 50
    qrCard:SetFrameStrata("DIALOG")

    qrCard:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile     = false,
        edgeSize = 12,
        insets   = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    qrCard:SetBackdropColor(1, 1, 1, 1)         -- чисто белая карточка
    qrCard:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)

    --------------------------------------------------
    -- Внутри карточки — поле для QR (уменьшенное)
    --------------------------------------------------
    local qrFrame = CreateFrame("Frame", "TWOFANozdorQRFrame", qrCard)
    qrFrame:SetSize(210, 210)
    qrFrame:SetPoint("CENTER")
    qrFrame:SetFrameStrata("DIALOG")

    f.QRFrame = qrFrame
    f.QRCard  = qrCard

    --------------------------------------------------
    -- Поле ввода для 6-значного кода активации
    --------------------------------------------------
    local codeLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    codeLabel:SetPoint("TOP", qrCard, "BOTTOM", 0, -10)
    codeLabel:SetText("Введите 6-значный код для активации:")

    -- Поле ввода кода (центрированное)
    local codeEditBox = CreateFrame("EditBox", "TWOFANozdorCodeEditBox", f, "InputBoxTemplate")
    codeEditBox:SetSize(120, 40)
    codeEditBox:SetPoint("TOP", codeLabel, "BOTTOM", 0, -6)
    codeEditBox:SetPoint("LEFT", f, "LEFT", 115, 0) -- Центрируем (350 - 120) / 2 = 115
    codeEditBox:SetMaxLetters(6)
    codeEditBox:SetNumeric(true) -- Только цифры
    codeEditBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    codeEditBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)

    -- Контейнер для кнопок активации/отключения
    local buttonContainer = CreateFrame("Frame", nil, f)
    buttonContainer:SetSize(220, 30)
    buttonContainer:SetPoint("TOP", codeEditBox, "BOTTOM", 0, -3)
    buttonContainer:SetPoint("LEFT", f, "LEFT", 65, 0) -- Центрируем (350 - 220) / 2 = 65

    -- Кнопка активации
    local activateButton = CreateFrame("Button", nil, buttonContainer, "UIPanelButtonTemplate")
    activateButton:SetSize(100, 30)
    activateButton:SetPoint("LEFT", buttonContainer, "LEFT", 0, 0)
    activateButton:SetText("Активировать")
    
    -- Устанавливаем белый текст на кнопке
    local activateButtonText = activateButton:GetFontString()
    if activateButtonText then
        activateButtonText:SetTextColor(1, 1, 1, 1) -- Белый цвет
    end
    
    -- Кнопка отключения
    local deactivateButton = CreateFrame("Button", nil, buttonContainer, "UIPanelButtonTemplate")
    deactivateButton:SetSize(100, 30)
    deactivateButton:SetPoint("LEFT", activateButton, "RIGHT", 10, 0)
    deactivateButton:SetText("Отключить")
    
    -- Устанавливаем белый текст на кнопке отключения
    local deactivateButtonText = deactivateButton:GetFontString()
    if deactivateButtonText then
        deactivateButtonText:SetTextColor(1, 1, 1, 1) -- Белый цвет
    end
    
    -- Функция для проверки и активации/деактивации кнопок
    local function UpdateButtons()
        local code = codeEditBox:GetText()
        if code and code ~= "" and string.len(code) == 6 then
            activateButton:Enable()
            deactivateButton:Enable()
        else
            activateButton:Disable()
            deactivateButton:Disable()
        end
    end
    
    -- Изначально кнопки неактивны
    activateButton:Disable()
    deactivateButton:Disable()
    
    -- Обновляем состояние кнопок при изменении текста
    codeEditBox:SetScript("OnTextChanged", function(self)
        UpdateButtons()
    end)
    
    activateButton:SetScript("OnClick", function(self)
        local code = codeEditBox:GetText()
        if code and code ~= "" and string.len(code) == 6 then
            -- Отправляем команду активации
            local command = ".account 2fa setup " .. code
            if ChatFrame1 and ChatFrame1.editBox then
                ChatFrame1.editBox:SetText(command)
                ChatEdit_SendText(ChatFrame1.editBox, 0)
            else
                SendChatMessage(command, "SAY")
            end
        end
    end)
    
    deactivateButton:SetScript("OnClick", function(self)
        local code = codeEditBox:GetText()
        if code and code ~= "" and string.len(code) == 6 then
            -- Отправляем команду отключения
            local command = ".account 2fa remove " .. code
            if ChatFrame1 and ChatFrame1.editBox then
                ChatFrame1.editBox:SetText(command)
                ChatEdit_SendText(ChatFrame1.editBox, 0)
            else
                SendChatMessage(command, "SAY")
            end
        end
    end)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -5, -5)

    f:Hide()
end

-- таблица текстур-клеток QR
local TWOFANozdor_QRTextures = nil
local TWOFANozdor_LastMatrixSize = 0

local function TWOFANozdor_DrawQR(matrix)
    TWOFANozdor_CreateFrame()

    local qrFrame = TWOFANozdorFrame.QRFrame
    if not qrFrame or not matrix then
        return
    end

    local size = #matrix
    if size <= 0 then
        return
    end

    local maxPixels = 210               -- вписываем QR в уменьшенную карточку
    local cellSize = math.floor(maxPixels / size)
    if cellSize < 2 then
        cellSize = 2
    end

    local qrSizePixels = cellSize * size
    qrFrame:SetSize(qrSizePixels, qrSizePixels)

    if not TWOFANozdor_QRTextures or TWOFANozdor_LastMatrixSize ~= size then
        TWOFANozdor_QRTextures = {}
        TWOFANozdor_LastMatrixSize = size

        for x = 1, size do
            TWOFANozdor_QRTextures[x] = {}
            for y = 1, size do
                local tex = qrFrame:CreateTexture(nil, "ARTWORK")
                tex:SetSize(cellSize, cellSize)
                tex:SetPoint("TOPLEFT", (x - 1) * cellSize, - (y - 1) * cellSize)
                tex:SetTexture(0, 0, 0, 1) -- чёрные квадраты QR
                TWOFANozdor_QRTextures[x][y] = tex
            end
        end
    end

    for x = 1, size do
        for y = 1, size do
            local tex = TWOFANozdor_QRTextures[x][y]
            if matrix[x][y] > 0 then
                tex:Show()
            else
                tex:Hide()
            end
        end
    end
end

local function TWOFANozdor_Show(key, matrix)
    TWOFANozdor_CreateFrame()

    TWOFANozdor_LastKey = key
    TWOFANozdor_LastQR  = matrix

    TWOFANozdorFrame:Show()
    TWOFANozdorEditBox:SetText(key or "")
    TWOFANozdorEditBox:SetFocus()

    local text = TWOFANozdorEditBox:GetText() or ""
    TWOFANozdorEditBox:HighlightText(0, string.len(text))

    if matrix then
        TWOFANozdor_DrawQR(matrix)
    end
end

------------------------------------------------------
-- Обработка системных сообщений (ловим ключ)
------------------------------------------------------

local eventFrame = CreateFrame("Frame", "TWOFANozdorEventFrame", UIParent)
eventFrame:RegisterEvent("CHAT_MSG_SYSTEM")

eventFrame:SetScript("OnEvent", function(self, event, msg)
    -- Обработка системных сообщений (ловим ключ)
    if type(msg) ~= "string" then
        return
    end

    -- Пример: "Ваш ключ 2FA: 5HNKCL37JBDIJP5AZ3IO46QPGIKD63O5"
    local key = msg:match("Ваш ключ 2FA:%s*(%S+)")

    if not key then
        key = msg:match("Your 2FA key:%s*(%S+)")
            or msg:match("2FA key:%s*(%S+)")
    end

    if not key then
        return
    end

    local matrix = nil

    if TWOFANozdor_CheckQRLib() then
        local url = TWOFANozdor_BuildTOTPUrl(key)
        local ok, tab_or_message = qrencode.qrcode(url)
        if ok then
            matrix = tab_or_message
        end
    end

    TWOFANozdor_Show(key, matrix)
end)

------------------------------------------------------
-- Slash-команда /2fa — повторно открыть окно
------------------------------------------------------

SLASH_TWOFANozdor1 = "/2fa"

SlashCmdList["TWOFANozdor"] = function(msg)
    if TWOFANozdor_LastKey then
        TWOFANozdor_Show(TWOFANozdor_LastKey, TWOFANozdor_LastQR)
    else
        -- Отправляем команду в чат автоматически
        -- Используем ChatFrame1 для отправки команды GM
        if ChatFrame1 and ChatFrame1.editBox then
            ChatFrame1.editBox:SetText(".account 2fa setup 1")
            ChatEdit_SendText(ChatFrame1.editBox, 0)
        else
            -- Fallback: отправляем через SendChatMessage
            SendChatMessage(".account 2fa setup 1", "SAY")
        end
    end
end
