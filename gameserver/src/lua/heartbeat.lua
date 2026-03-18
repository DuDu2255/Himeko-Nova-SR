local function setTextComponent(path, newText)
    local obj = CS.UnityEngine.GameObject.Find(path)
    if not obj then return false end

    local localized = obj:GetComponentInChildren(typeof(CS.RPG.Client.LocalizedText))
    if localized then
        localized.text = newText
        return true
    end
    return false
end

setTextComponent(
    "UIRoot/AboveDialog/BetaHintDialog(Clone)",
    "<color=#FF7BEA>CastoricePS is free and open source.</color>"
)

setTextComponent(
    "VersionText",
    "<color=#A675FF>HyacineLover | CastoricePS</color>"
)
