// preload.js — exposes window.pomoppi to the widget window (SPEC.md §6, §12).
// contextBridge only: named methods, no generic invoke/send passthrough.
'use strict';

const { contextBridge, ipcRenderer } = require('electron');

function subscribe(channel, callback) {
  const listener = (_event, payload) => callback(payload);
  ipcRenderer.on(channel, listener);
  return () => ipcRenderer.removeListener(channel, listener);
}

contextBridge.exposeInMainWorld('pomoppi', {
  onState: (cb) => subscribe('pomoppi:state', cb),
  onSettings: (cb) => subscribe('pomoppi:settings', cb),
  getState: () => ipcRenderer.invoke('pomoppi:getState'),
  getSettings: () => ipcRenderer.invoke('pomoppi:getSettings'),
  start: () => ipcRenderer.invoke('pomoppi:start'),
  pause: () => ipcRenderer.invoke('pomoppi:pause'),
  reset: () => ipcRenderer.invoke('pomoppi:reset'),
  skip: () => ipcRenderer.invoke('pomoppi:skip'),
  dismissRing: () => ipcRenderer.invoke('pomoppi:dismissRing'),
  openSettings: () => ipcRenderer.invoke('pomoppi:openSettings'),
  openTask: () => ipcRenderer.invoke('pomoppi:openTask'),
  adjustFocusMinutes: (delta) => ipcRenderer.invoke('pomoppi:adjustFocusMinutes', delta),
  setFocusDuration: (totalSeconds) => ipcRenderer.invoke('pomoppi:setFocusDuration', totalSeconds),
  setLongBreakEvery: (n) => ipcRenderer.invoke('pomoppi:setLongBreakEvery', n),
  moveBy: (dx, dy) => ipcRenderer.invoke('pomoppi:moveBy', dx, dy),
  onSnapshotRequest: (cb) => subscribe('pomoppi:snapshot-request', cb),
  saveSnapshot: (svg) => ipcRenderer.invoke('pomoppi:saveSnapshot', svg),
  toggleAlwaysOnTop: () => ipcRenderer.invoke('pomoppi:toggleAlwaysOnTop'),
  hideWidget: () => ipcRenderer.invoke('pomoppi:hideWidget'),
});
