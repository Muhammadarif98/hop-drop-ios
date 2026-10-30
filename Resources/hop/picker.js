(() => {
  let close;
  const icons={gallery:'<rect x="3" y="3" width="18" height="18" rx="4"/><circle cx="8" cy="8" r="1.5"/><path d="m4 17 5-5 4 4 3-3 4 5"/>',files:'<path d="M7 3h7l4 4v14H7z"/><path d="M14 3v5h4M10 12h5M10 16h5"/>',folder:'<path d="M3 7a2 2 0 0 1 2-2h5l2 2h7a2 2 0 0 1 2 2v10H3z"/>'};
  const labels={ru:{title:'Отправить файлы',sub:'Выберите, откуда добавить файлы',gallery:['Галерея','Фото и видео'],files:['Проводник','Документы и любые файлы'],folder:['Папка','Отправить папку целиком'],cancel:'Отмена'},en:{title:'Send files',sub:'Choose where to add files from',gallery:['Gallery','Photos and videos'],files:['File browser','Documents and any files'],folder:['Folder','Send an entire folder'],cancel:'Cancel'}};
  window.hopCloseSourcePicker=()=>{if(!close)return false;close(null);return true;};
  window.hopSourcePicker=()=>new Promise(resolve=>{
    if(close){resolve(null);return;}
    const t=labels[window.hopI18n?.language==='en'?'en':'ru'];const focus=document.activeElement;
    const overlay=document.createElement('div');overlay.className='source-overlay';
    const card=document.createElement('section');card.className='source-card';card.setAttribute('role','dialog');card.setAttribute('aria-modal','true');card.setAttribute('aria-labelledby','sourceTitle');
    const title=document.createElement('h2');title.id='sourceTitle';title.textContent=t.title;
    const sub=document.createElement('p');sub.className='source-sub';sub.textContent=t.sub;card.append(title,sub);
    const finish=value=>{
      if(close!==finish)return;close=null;overlay.classList.add('closing');
      document.removeEventListener('keydown',onKey,true);setTimeout(()=>overlay.remove(),180);
      focus?.focus();resolve(value);
    };
    close=finish;
    for(const source of ['gallery','files','folder']) {
      const button=document.createElement('button');button.type='button';button.className='source-option';button.dataset.source=source;
      const icon=document.createElement('span');icon.className='source-icon '+source;icon.innerHTML='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">'+icons[source]+'</svg>';
      const body=document.createElement('span');body.className='source-option-body';const name=document.createElement('strong');name.textContent=t[source][0];const detail=document.createElement('small');detail.textContent=t[source][1];body.append(name,detail);
      const arrow=document.createElement('span');arrow.className='source-arrow';arrow.textContent='›';button.append(icon,body,arrow);button.addEventListener('click',()=>finish(source));card.append(button);
    }
    const cancel=document.createElement('button');cancel.type='button';cancel.className='btn source-cancel';cancel.textContent=t.cancel;cancel.addEventListener('click',()=>finish(null));card.append(cancel);
    overlay.append(card);overlay.addEventListener('click',event=>{if(event.target===overlay)finish(null);});
    function onKey(event){if(event.key==='Escape'){event.preventDefault();event.stopImmediatePropagation();finish(null);}else if(event.key==='Tab'){const buttons=[...card.querySelectorAll('button')];const index=buttons.indexOf(document.activeElement);event.preventDefault();buttons[(index+(event.shiftKey?-1:1)+buttons.length)%buttons.length].focus();}}
    document.addEventListener('keydown',onKey,true);document.body.append(overlay);card.querySelector('button').focus();
  });
})();
