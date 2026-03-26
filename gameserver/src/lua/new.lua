--local function onDialogClosed()
    --CS.UnityEngine.Application.OpenURL("https://discord.gg/CastoricePS")
--end

local function show_hint()
    local text = "欢迎来到 CastoricePS\n"
    text = text .. "此服务端完全免费\n"
    text = text .. "加入我们的 Discord 了解更多信息：https://discord.gg/CastoricePS\n"
    CS.RPG.Client.ConfirmDialogUtil.ShowCustomOkCancelHint(text, onDialogClosed)
end

show_hint()