// preload-settings.js — exposes window.pomoppiSettings to the settings and task
// windows (SPEC.md §6, §12). contextBridge only: named methods, no generic
// invoke/send passthrough.
'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('pomoppiSettings', {
  get: () => ipcRenderer.invoke('pomoppiSettings:get'),
  set: (patch) => ipcRenderer.invoke('pomoppiSettings:set', patch),
  reset: () => ipcRenderer.invoke('pomoppiSettings:reset'),
  pickVault: () => ipcRenderer.invoke('pomoppiSettings:pickVault'),
  testLog: () => ipcRenderer.invoke('pomoppiSettings:testLog'),
  close: () => ipcRenderer.invoke('pomoppiSettings:close'),
  getTask: () => ipcRenderer.invoke('pomoppiSettings:getTask'),
  setTask: (text) => ipcRenderer.invoke('pomoppiSettings:setTask', text),
});
