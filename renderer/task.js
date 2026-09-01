// Task input dialog logic
const input = document.getElementById('task-input');
const okBtn = document.getElementById('ok-btn');
const cancelBtn = document.getElementById('cancel-btn');

async function handleOK() {
  const task = input.value;
  try {
    await window.pomoppiSettings.setTask(task);
    window.pomoppiSettings.close();
  } catch (e) {
    console.error('Failed to set task:', e);
  }
}

function handleCancel() {
  window.pomoppiSettings.close();
}

// Event listeners
okBtn.addEventListener('click', handleOK);
cancelBtn.addEventListener('click', handleCancel);

input.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') {
    e.preventDefault();
    handleOK();
  } else if (e.key === 'Escape') {
    e.preventDefault();
    handleCancel();
  }
});

// Paints this window in the user's two-colour theme. task.css writes every
// colour as var(--ink) / var(--paper) and ships the black-on-white defaults,
// so a failure here leaves a correct-looking window rather than an unstyled
// one. Setting a custom property through the CSSOM is not an inline style
// attribute, so style-src 'self' does not block it -- the widget already
// drives --scale the same way.
function applyTheme(settings) {
  if (!settings) return;
  const root = document.documentElement;
  if (settings.inkColor) root.style.setProperty('--ink', settings.inkColor);
  if (settings.paperColor) root.style.setProperty('--paper', settings.paperColor);
}

// Initialize
async function init() {
  // Theme first and on its own: a settings read that fails must not cost us
  // the task text, and a task read that fails must not leave the window
  // unthemed. This dialog is only ever open for a few seconds, so it reads
  // the theme once at open rather than subscribing to changes.
  try {
    applyTheme(await window.pomoppiSettings.get());
  } catch (e) {
    console.error('Failed to load theme:', e);
  }

  try {
    const task = await window.pomoppiSettings.getTask();
    input.value = task || '';
    input.focus();
    input.select();
  } catch (e) {
    console.error('Failed to load task:', e);
  }
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', init);
} else {
  init();
}
