#include "zml_plugin.h"
#include "patch.hpp"
#include "fpvlink.hpp"
#include <filesystem>
#include <fstream>
#include <iterator>
#include <stdexcept>
namespace {
const ZmlHost* hostApi{};
std::string helper;
int transform(void* camera,const char* source,size_t length,ZmlSink sink,void* writer) noexcept {
    try {
        if(!source || !sink || length>512*1024)return 0;
        std::string output;
        if(!freecam::patch(std::string_view(source,length),helper,camera!=nullptr,output)) {
            hostApi->log(hostApi->owner,"FreeCam source contract rejected");return 0;
        }
        sink(writer,output.data(),output.size());return 1;
    }catch(...){return 0;}
}
int start(const ZmlHost* host) noexcept {
    try {
        if(!host || host->size!=sizeof(ZmlHost) || host->abi!=1 || !host->log || !host->transform_lua || !host->mod_directory)return 0;
        auto root=std::filesystem::path(std::u8string(reinterpret_cast<const char8_t*>(host->mod_directory)));
        auto read=[&](const wchar_t* name) {
            auto p=root/name;
            if(std::filesystem::file_size(p)>64*1024)throw std::runtime_error("helper exceeds limit");
            std::ifstream f(p,std::ios::binary);std::string bytes{std::istreambuf_iterator<char>(f),{}};
            if(!f || bytes.empty() || bytes.find('\0')!=bytes.npos)throw std::runtime_error("invalid helper");return bytes;
        };
        helper="local ZMLFCFactory=(function()\n"+read(L"freecam_core.lua")+"\nend)()\n"+
            "local ZMLFCFpv=(function()\n"+read(L"fpv_link.lua")+"\nend)()\n"+read(L"freecam.lua");
        if(helper.size()>96*1024)return 0;
        hostApi=host;
        freecam::fpv::start(host);
        return host->transform_lua(host->owner,"UI/Panels/BattleAction/BattleActionCtrl",transform,nullptr) &&
            host->transform_lua(host->owner,"UI/Panels/LevelCamera/LevelCameraCtrl",transform,reinterpret_cast<void*>(1));
    }catch(...){return 0;}
}
const ZmlPlugin plugin{sizeof(ZmlPlugin),1,"freecam",start};
}
extern "C" __declspec(dllexport) const ZmlPlugin* ZML_PluginV1(){return &plugin;}
