const done = arguments[arguments.length - 1];
(async () => {
  const m = await import('/explorer/assets/world-CblDwDXV.js');
  const l = await import('/explorer/assets/locomotion--uMNyio1.js');
  const provider = await m.H();
  if (!provider) throw Error('existing signing key unavailable');
  let identity = await m.D(provider);
  const agent = m.q(m.F(identity.networkId));
  if (agent?.namespace !== 'human:5pU3X8evhfH09g1ctl0LRRP80zmhd6M7g8OQ7DyOeaE' ||
      agent.instanceText !== 'me.') throw Error('selected agent changed');
  const navigation = await m.u(identity, agent);
  const world = navigation.world ?? navigation.lobby ?? navigation;
  const refs = {namespace: agent.namespace + '/lobby',
    anchor: Uint8Array.from('7082C150269E5B82754C06CB7928F6E55FFBCEDABD25E642C2CCF874A3A6F77F'.match(/../g), x => parseInt(x,16))};
  const request = (mode,goal) => m.N(identity,{mode,agent,goal},mode === 'execute' ? {onTerminal:()=>false} : {});
  globalThis.quod27Evidence = {
    read: goal => request('read',goal),
    execute: goal => request('execute',goal),
    cursor: goal => request('cursor',goal),
    command: (cursor,command) => m.M(identity,cursor,command),
    control: goal => request('control',goal),
    pending: async () => (await m.k(identity)).map(row => ({id:row.id,agent:row.agent,context:row.context})),
    resolve: async () => (await m.j(identity)).map(row => ({id:row.id,reply:row.reply,error:String(row.error ?? '')})),
    renew: async () => { identity = await m.D(provider); return {renewed:true}; },
    scoped: goal => m.n(refs,m.h(goal)),
    moveGoal: (frame,control,sequence,input) => l.n(refs,frame,l.r(control),BigInt(sequence),m.h(input)),
    format: binding => m.y(m.h(binding)),
  };
  done({ready:true,agent:{namespace:agent.namespace,anchor:agent.anchor,instanceText:agent.instanceText},navigation});
})().catch(error => done({error:String(error)}));
