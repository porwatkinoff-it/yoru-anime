from pathlib import Path
import plistlib
p=Path(__file__).parent
ids={k:f'{i:024X}' for i,k in enumerate(['project','main','sourcegroup','products','app','target','sources','frameworks','resources','configs','tconfigs','debug','release','tdbg','trel','api','appswift','player','apiBuild','appBuild','playerBuild','vlc','vlcBuild','frameworkgroup','embed','vlcEmbed','assets','assetsBuild','sync','syncBuild','screens','screensBuild','downloads','downloadsBuild','servers','serversBuild','update','updateBuild'],1)}
def I(k):return ids[k]
obj={}
def add(k,s):obj[I(k)]=s
add('project',f'isa=PBXProject; buildConfigurationList={I("configs")}; compatibilityVersion="Xcode 14.0"; mainGroup={I("main")}; productRefGroup={I("products")}; projectDirPath=""; targets=({I("target")}); attributes={{LastUpgradeCheck=1600;}};')
add('main',f'isa=PBXGroup; children=({I("sourcegroup")},{I("frameworkgroup")},{I("assets")},{I("products")}); sourceTree="<group>";')
add('sourcegroup',f'isa=PBXGroup; path=NightAnime; sourceTree="<group>"; children=({I("api")},{I("appswift")},{I("player")},{I("sync")},{I("screens")},{I("downloads")},{I("servers")},{I("update")});')
add('frameworkgroup',f'isa=PBXGroup; name=Frameworks; sourceTree="<group>"; children=({I("vlc")});')
add('products',f'isa=PBXGroup; name=Products; sourceTree="<group>"; children=({I("app")});')
add('app','isa=PBXFileReference; explicitFileType=wrapper.application; path="Night Anime.app"; sourceTree=BUILT_PRODUCTS_DIR;')
for k,n in [('api','API.swift'),('appswift','NightAnimeApp.swift'),('player','NativePlayer.swift'),('sync','Sync.swift'),('screens','Screens.swift'),('downloads','Downloads.swift'),('servers','Servers.swift'),('update','Update.swift')]: add(k,f'isa=PBXFileReference; lastKnownFileType=sourcecode.swift; path={n}; sourceTree="<group>";')
for k,r in [('apiBuild','api'),('appBuild','appswift'),('playerBuild','player'),('vlcBuild','vlc'),('syncBuild','sync'),('screensBuild','screens'),('downloadsBuild','downloads'),('serversBuild','servers'),('updateBuild','update')]:add(k,f'isa=PBXBuildFile; fileRef={I(r)};')
add('vlc','isa=PBXFileReference; lastKnownFileType=wrapper.xcframework; path="../reference/VLCKit-all.xcframework"; sourceTree="<group>";')
add('vlcEmbed',f'isa=PBXBuildFile; fileRef={I("vlc")}; settings={{ATTRIBUTES=(RemoveHeadersOnCopy);}};')
add('embed',f'isa=PBXCopyFilesBuildPhase; buildActionMask=2147483647; dstPath=""; dstSubfolderSpec=10; files=({I("vlcEmbed")}); name="Embed Frameworks"; runOnlyForDeploymentPostprocessing=0;')
add('sources',f'isa=PBXSourcesBuildPhase; buildActionMask=2147483647; files=({I("apiBuild")},{I("appBuild")},{I("playerBuild")},{I("syncBuild")},{I("screensBuild")},{I("downloadsBuild")},{I("serversBuild")},{I("updateBuild")}); runOnlyForDeploymentPostprocessing=0;')
add('frameworks',f'isa=PBXFrameworksBuildPhase; buildActionMask=2147483647; files=({I("vlcBuild")}); runOnlyForDeploymentPostprocessing=0;')
add('assets','isa=PBXFileReference; lastKnownFileType=folder.assetcatalog; path=NightAnime/Assets.xcassets; sourceTree="<group>";')
add('assetsBuild',f'isa=PBXBuildFile; fileRef={I("assets")};')
add('resources',f'isa=PBXResourcesBuildPhase; buildActionMask=2147483647; files=({I("assetsBuild")}); runOnlyForDeploymentPostprocessing=0;')
add('target',f'isa=PBXNativeTarget; buildConfigurationList={I("tconfigs")}; buildPhases=({I("sources")},{I("frameworks")},{I("resources")},{I("embed")}); buildRules=(); dependencies=(); name=NightAnime; productName="Night Anime"; productReference={I("app")}; productType="com.apple.product-type.application";')
for key,configs in [('configs',['debug','release']),('tconfigs',['tdbg','trel'])]:add(key,'isa=XCConfigurationList; buildConfigurations=('+','.join(I(c) for c in configs)+'); defaultConfigurationIsVisible=0; defaultConfigurationName=Release;')
for key,name in [('debug','Debug'),('release','Release')]:add(key,f'isa=XCBuildConfiguration; name={name}; buildSettings={{SDKROOT=iphoneos; IPHONEOS_DEPLOYMENT_TARGET=17.0; CLANG_ENABLE_MODULES=YES; SWIFT_VERSION=5.0;}};')
links='$(inherited) -ObjC -lc++ -lxml2 -lz -lbz2 -liconv -framework QuartzCore -framework CoreText -framework AVFoundation -framework Security -framework CFNetwork -framework AudioToolbox -framework OpenGLES -framework CoreGraphics -framework VideoToolbox -framework CoreMedia'
for key,name in [('tdbg','Debug'),('trel','Release')]:add(key,f'isa=XCBuildConfiguration; name={name}; buildSettings={{'+('SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG; SWIFT_OPTIMIZATION_LEVEL="-Onone"; ' if name=='Debug' else 'SWIFT_OPTIMIZATION_LEVEL="-O"; ENABLE_DEBUG_DYLIB=NO; ENABLE_PREVIEWS=NO; SWIFT_COMPILATION_MODE=wholemodule; ')+f'ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon; PRODUCT_BUNDLE_IDENTIFIER=com.resvvt.nightanime.ios; PRODUCT_NAME="Night Anime"; INFOPLIST_FILE=NightAnime/Info.plist; TARGETED_DEVICE_FAMILY="1,2"; SWIFT_VERSION=5.0; CODE_SIGNING_ALLOWED=NO; ENABLE_BITCODE=NO; OTHER_LDFLAGS="{links}"; LD_RUNPATH_SEARCH_PATHS="$(inherited) @executable_path/Frameworks";}};')
(p/'NightAnime.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion=1;classes={};objectVersion=56;objects={\n'+'\n'.join(k+'={'+v+'};' for k,v in obj.items())+'\n};rootObject='+I('project')+';}\n')
info={'CFBundleDisplayName':'Yoru Anime','CFBundleDevelopmentRegion':'ru','CFBundleLocalizations':['ru'],'CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)','CFBundleExecutable':'$(EXECUTABLE_NAME)','CFBundleName':'Yoru Anime','CFBundlePackageType':'APPL','CFBundleShortVersionString':'2.0.13','CFBundleVersion':'24','LSRequiresIPhoneOS':True,'UILaunchScreen':{},'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight'],'NSAppTransportSecurity':{'NSAllowsArbitraryLoadsForMedia':True},'UIRequiresFullScreen':False,'NSLocalNetworkUsageDescription':'Yoru Anime находит приставку Yoru TV в домашней сети, чтобы синхронизировать историю просмотра.','NSBonjourServices':['_nightanime._tcp']}
(p/'NightAnime/Info.plist').write_bytes(plistlib.dumps(info))
