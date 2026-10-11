#pragma once
#include <string>
#include <string_view>
#include <utility>
namespace freecam {
inline size_t count(std::string_view source,std::string_view key) {
    size_t n=0,p=0;while((p=source.find(key,p))!=source.npos){++n;p+=key.size();}return n;
}
// camera==true patches the level camera input path, otherwise the gameplay
// controller that owns the module lifetime.
inline bool patch(std::string_view source,std::string_view helper,bool camera,std::string& output) {
    constexpr std::string_view marker="-- ZML_FREECAM_V1";
    if(source.empty() || source.size()>512*1024 || source.find('\0')!=source.npos || count(source,marker))return false;
    const auto cls=camera?"LevelCameraCtrl":"BattleActionCtrl";
    const std::string declaration=std::string(cls)+" = HL.Class('"+cls+"', uiCtrl.UICtrl)";
    const std::string commit=std::string("HL.Commit(")+cls+")";
    if(count(source,declaration)!=1 || count(source,commit)!=1)return false;
    std::string s(source);
    if(camera) {
        constexpr std::string_view move="LevelCameraCtrl._MoveCamera = HL.Method(HL.Userdata) << function(self, delta)";
        constexpr std::string_view zoom="LevelCameraCtrl.ZoomCamera = HL.Method(HL.Number) << function(self, delta)";
        if(count(source,move)!=1 || count(source,zoom)!=1)return false;
        s.insert(s.find(move)+move.size(),"\n    local fc=rawget(_G,'ZMLFreecam')\n    if fc and fc.move(self,delta) then return end\n");
        s.insert(s.find(zoom)+zoom.size(),"\n    local fc=rawget(_G,'ZMLFreecam')\n    if fc and fc.holding() then return end\n");
    } else {
        if(helper.empty() || helper.size()>96*1024 || helper.find('\0')!=helper.npos)return false;
        const std::string show=std::string(cls)+".OnShow = HL.Override() << function(self)";
        const std::string hide=std::string(cls)+".OnHide = HL.Override() << function(self)";
        const std::string close=std::string(cls)+".OnClose = HL.Override() << function(self)";
        for(const auto& key:{show,hide,close})if(count(source,key)!=1)return false;
        s.insert(s.find(declaration),std::string(marker)+"\nlocal ZMLFC = (function()\n"+std::string(helper)+"\nend)()\n");
        for(const auto& [key,call]:{std::pair{show,"show"},std::pair{hide,"hide"},std::pair{close,"close"}})
            s.insert(s.find(key)+key.size(),std::string("\n    ZMLFC.")+call+"(self)\n");
    }
    if(s.size()>768*1024)return false;
    output=std::move(s);return true;
}
}
