function () {
  const sockets = this.filter(socket => socket.url.includes('/api/simulation') && socket.readyState === 1);
  if (sockets.length !== 1) throw Error('expected exactly one existing simulation socket');
  const socket = sockets[0], events = [], waiters = new Set();
  const observer = {events, last:null, projection:null};
  const matches = (message, target) => {
    if (target.revision !== undefined) return message.type === 'projection' && message.selection === 'active' &&
      message.control.includes('controlled_agent(pilot,' + target.revision + ',2,1,');
    if (target.sequence !== undefined) return message.frame?.control_state?.sequence === String(target.sequence) &&
      message.frame.control_state.pending === false;
    return message.selection === target.selection;
  };
  const receive = event => {
    const message = JSON.parse(event.data);
    if (!['projection','simulation_frame','refresh','unavailable'].includes(message.type)) return;
    events.push({at:Date.now(),data:message});
    if (events.length > 2048) events.shift();
    if (message.type === 'projection') observer.projection = message;
    if (message.frame) observer.last = message.frame;
    for (const waiter of waiters) if (matches(message,waiter.target)) waiter.finish(message);
  };
  observer.wait = target => new Promise(resolve => {
    const existing = [...events].reverse().find(event => matches(event.data,target));
    if (existing) return resolve(existing.data);
    const waiter = {target,finish:message => {clearTimeout(timer);waiters.delete(waiter);resolve(message);}};
    const timer = setTimeout(() => waiter.finish({error:'observation deadline',target}),8000);
    waiters.add(waiter);
  });
  observer.dispose = () => {socket.removeEventListener('message',receive);for(const w of waiters) w.finish({error:'disposed'});};
  socket.addEventListener('message',receive);
  globalThis.quod27Observe = observer;
  return {attached:true,sockets:sockets.length};
}
