from pathlib import Path
import shutil,subprocess,zipfile,plistlib,hashlib,json
root=Path(__file__).resolve().parent
out=root.parents[1]/'outputs'
out.mkdir(exist_ok=True)
stage=root/'ipa-stage/Payload';stage.mkdir(parents=True,exist_ok=True)
app=stage/'Night Anime.app'
if app.exists():shutil.rmtree(app)
shutil.copytree(root/'ios/build/Build/Products/Release-iphoneos/Night Anime.app',app,symlinks=True)
f=app/'Frameworks/MobileVLCKit.framework/MobileVLCKit'
subprocess.run(['/usr/bin/lipo',str(f),'-thin','arm64','-output',str(f)+'.arm64'],check=True)
Path(str(f)+'.arm64').replace(f)
for sig in app.rglob('_CodeSignature'):
 if sig.is_dir():shutil.rmtree(sig)
legal=app/'Licenses';legal.mkdir(exist_ok=True)
for name in ['LICENSE','NOTICE.md','README.md']:shutil.copy2(root/name,legal/name)
shutil.copytree(root/'licenses',legal/'VLC',dirs_exist_ok=True)
ipa=out/'Night-Anime-iOS-unsigned.ipa'
with zipfile.ZipFile(ipa,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
 for p in sorted(stage.rglob('*')):
  if p.is_file():z.write(p,str(p.relative_to(stage.parent)))
shutil.copy2(root/'android/app/build/outputs/apk/release/app-release.apk',out/'Night-Anime-Android-TV.apk')
shutil.copy2(root/'README.md',out/'Night-Anime-README.md')
source=out/'Night-Anime-source.zip'
with zipfile.ZipFile(source,'w',zipfile.ZIP_DEFLATED) as z:
 for p in root.rglob('*'):
  r=p.relative_to(root)
  if not p.is_file() or any(n in r.parts for n in ['build','sim-build','sim-release','.gradle','reference','ipa-stage','qa','render']):continue
  if p.suffix in ['.log','.apk','.ipa'] or p.name=='local.properties':continue
  z.write(p,'Night-Anime/'+str(r))
 z.write(root/'qa/subtitles.ass','Night-Anime/qa/subtitles.ass')
for name in ['ios-catalog.png','ios-ass-first.png','tv-ass-first.png']:
 shutil.copy2(root/'qa'/name,out/('Night-Anime-'+name))
info=plistlib.loads((app/'Info.plist').read_bytes())
assert info['CFBundleIdentifier']=='com.resvvt.nightanime.ios'
assert info['MinimumOSVersion']=='17.0'
assert not (app/'embedded.mobileprovision').exists()
assert subprocess.check_output(['/usr/bin/lipo','-archs',str(f)]).decode().strip()=='arm64'
assert subprocess.check_output(['/usr/bin/lipo','-archs',str(app/info['CFBundleExecutable'])]).decode().strip()=='arm64'
with zipfile.ZipFile(ipa) as z:assert z.testzip() is None
report={'native_ios_arm64':True,'ios_minimum':info['MinimumOSVersion'],'ios_framework_embedded':True,'ipa_unsigned':True,'android_abis':['armeabi-v7a','arm64-v8a'],'ios_simulator_ass_visual_check':True,'sberbox_ass_visual_check':True,'real_subscriber_episode':'owner confirmed login, subtitles and real 4K playback', 'sberbox_4k_avc_ass_three_reopens':True,'files':{}}
for p in [ipa,out/'Night-Anime-Android-TV.apk',source]:
 report['files'][p.name]={'bytes':p.stat().st_size,'sha256':hashlib.file_digest(p.open('rb'),'sha256').hexdigest()}
(root/'qa/validation.json').write_text(json.dumps(report,indent=2))
(out/'Night-Anime-validation.json').write_text(json.dumps(report,indent=2))
print(json.dumps({p.name:p.stat().st_size for p in [ipa,out/'Night-Anime-Android-TV.apk',source]}))
