local util = require("xlua.util")

local toastQueue = {}
local isShowing = false

local function showToast(textname)
    local orig = CS.UnityEngine.GameObject.Find("UIRoot/AboveDialog/PileToastDialog(Clone)/PileContainer/HintInfoDialog(Clone)")
    if orig == nil then return false end

    local customHintGO = CS.UnityEngine.GameObject.Instantiate(orig)
    customHintGO.name = "CustomHint(Clone)"
    customHintGO.transform:SetParent(orig.transform.parent, false)
    customHintGO:SetActive(true)

    local textObj = customHintGO.transform:Find("Title/Text")
    if textObj == nil then return false end
    local localizedTextComponent = textObj:GetComponent(typeof(CS.RPG.Client.LocalizedText))
    if localizedTextComponent == nil then return false end
    localizedTextComponent.text = tostring(textname)
    return true
end

local function processQueue()
    if isShowing or #toastQueue == 0 then return end
    isShowing = true
    local text = table.remove(toastQueue, 1)
    showToast(text)
    isShowing = false
end

local function enqueue(text)
    table.insert(toastQueue, text)
    processQueue()
end

enqueue("CastoricePS Lua synced.")
