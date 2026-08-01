        local function setTextComponent(path, newText)
            local obj = CS.UnityEngine.GameObject.Find(path)
            if obj then
                local textComponent = obj:GetComponentInChildren(typeof(CS.RPG.Client.LocalizedText))
                if textComponent then
                    textComponent.text = newText
                end
            end
        end
        
        setTextComponent("UIRoot/AboveDialog/BetaHintDialog(Clone)", "<color=#E81E39>Himeko•NovaSR is a free and open source software.</color>")
        setTextComponent("VersionText", "<color=#E81E39>Visit discord.gg/reversedrooms for more info!</color>")
