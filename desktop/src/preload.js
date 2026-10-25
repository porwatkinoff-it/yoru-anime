// Мост между страницей и основным процессом: только нужные вызовы, без доступа к Node.
const { contextBridge, ipcRenderer } = require('electron');
const on = ch => fn => { const h = (_e, ...a) => fn(...a); ipcRenderer.on(ch, h); return () => ipcRenderer.removeListener(ch, h); };
contextBridge.exposeInMainWorld('yoru', {
  platform: process.platform,
  api: (path, params, auth) => ipcRenderer.invoke('api', path, params, auth),
  login: (email, password) => ipcRenderer.invoke('login', email, password),
  logout: () => ipcRenderer.invoke('logout'),
  signedIn: () => ipcRenderer.invoke('signedIn'),
  text: url => ipcRenderer.invoke('text', url),
  openExternal: url => ipcRenderer.invoke('openExternal', url),
  version: () => ipcRenderer.invoke('version'),
  fullscreen: on => ipcRenderer.invoke('fullscreen', on),
  download: (url, name) => ipcRenderer.invoke('download', url, name),
  showFile: file => ipcRenderer.invoke('showFile', file),
  checkUpdate: () => ipcRenderer.invoke('checkUpdate'),
  installUpdate: (url, name) => ipcRenderer.invoke('installUpdate', url, name),
  onUpdateProgress: on('updateProgress'),
  onDownloadProgress: on('downloadProgress'),
  hasBattery: () => ipcRenderer.invoke('hasBattery'),
  serverSpeed: url => ipcRenderer.invoke('serverSpeed', url),
  dl: {
    list: () => ipcRenderer.invoke('dlList'),
    enqueue: meta => ipcRenderer.invoke('dlEnqueue', meta),
    retry: id => ipcRenderer.invoke('dlRetry', id),
    remove: ids => ipcRenderer.invoke('dlRemove', ids),
    text: id => ipcRenderer.invoke('dlText', id),
    space: () => ipcRenderer.invoke('dlSpace'),
    onChanged: on('dlChanged'),
    onDone: on('dlDone'),
    onServerFailed: on('serverFailed')
  },
  onFullscreen: on('fullscreenChanged')
});
