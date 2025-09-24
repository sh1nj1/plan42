import { registerGlobalHandlers } from './event_handlers';

if (!window.creativesDragDropInitialized) {
  window.creativesDragDropInitialized = true;
  registerGlobalHandlers();
}
