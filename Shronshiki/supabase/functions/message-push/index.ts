// Invoked only by the private database outbox, authenticated by its Vault secret.
const encoder=new TextEncoder();
const base64url=(value:Uint8Array)=>btoa(String.fromCharCode(...value)).replaceAll("+","-").replaceAll("/","_").replaceAll("=","");
const serviceHeaders=()=>({"apikey":Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,"Authorization":`Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!}`,"Content-Type":"application/json"});
async function rpc(name:string,body:unknown) {
 const response=await fetch(`${Deno.env.get("SUPABASE_URL")}/rest/v1/rpc/${name}`,{method:"POST",headers:serviceHeaders(),body:JSON.stringify(body),signal:AbortSignal.timeout(10000)});
 if(!response.ok) throw new Error("private RPC failed");
 const text=await response.text(); return text ? JSON.parse(text) : null;
}
async function equalSecret(a:string,b:string) {
 const left=new Uint8Array(await crypto.subtle.digest("SHA-256",encoder.encode(a)));
 const right=new Uint8Array(await crypto.subtle.digest("SHA-256",encoder.encode(b)));
 let delta=0; for(let i=0;i<left.length;i++) delta|=left[i]^right[i]; return delta===0;
}
let cachedAuth:{token:string,until:number}|undefined;
async function accessToken(account:{client_email:string,private_key:string}) {
 if(cachedAuth && cachedAuth.until>Date.now()) return cachedAuth.token;
 const now=Math.floor(Date.now()/1000);
 const header=base64url(encoder.encode(JSON.stringify({alg:"RS256",typ:"JWT"})));
 const payload=base64url(encoder.encode(JSON.stringify({iss:account.client_email,scope:"https://www.googleapis.com/auth/firebase.messaging",aud:"https://oauth2.googleapis.com/token",iat:now,exp:now+3600})));
 const pem=account.private_key.replace(/-----[^-]+-----/g,"").replace(/\s/g,"");
 const key=await crypto.subtle.importKey("pkcs8",Uint8Array.from(atob(pem),c=>c.charCodeAt(0)),{name:"RSASSA-PKCS1-v1_5",hash:"SHA-256"},false,["sign"]);
 const signature=await crypto.subtle.sign("RSASSA-PKCS1-v1_5",key,encoder.encode(`${header}.${payload}`));
 const assertion=`${header}.${payload}.${base64url(new Uint8Array(signature))}`;
 const response=await fetch("https://oauth2.googleapis.com/token",{method:"POST",headers:{"Content-Type":"application/x-www-form-urlencoded"},body:new URLSearchParams({grant_type:"urn:ietf:params:oauth:grant-type:jwt-bearer",assertion}),signal:AbortSignal.timeout(10000)});
 if(!response.ok) throw new Error("push authorization failed");
 const data=await response.json(); cachedAuth={token:data.access_token,until:Date.now()+3000000}; return cachedAuth.token;
}
Deno.serve(async request=>{
 if(request.method!=="POST") return new Response("Method not allowed",{status:405});
 let id:string|undefined;
 try {
  const config=await rpc("push_runtime_config",{});
  if(!config?.message_push_secret || !await equalSecret(request.headers.get("x-push-secret")??"",config.message_push_secret)) return new Response("Unauthorized",{status:401});
  const body=await request.json(); id=String(body.id??"");
  if(!/^\d+$/.test(id)) return new Response("Invalid event",{status:400});
  const notice=await rpc("claim_push_notice",{p_id:id});
  if(!notice) return new Response("Already handled");
  const tokens=notice.tokens as string[];
  let success=true; const invalid:string[]=[];
  if(tokens.length>0) {
   const account=JSON.parse(config.fcm_service_account);
   const auth=await accessToken(account);
   for(const token of tokens) {
    // Data-only: native code respects the current account and notification switch.
    const data={id:notice.id,user:notice.user,chat_id:notice.chat_id??"",room_code:notice.room_code??"",title:"Shronshiki",text:"Вам написали"};
    const result=await fetch(`https://fcm.googleapis.com/v1/projects/${account.project_id}/messages:send`,{method:"POST",headers:{"Authorization":`Bearer ${auth}`,"Content-Type":"application/json"},body:JSON.stringify({message:{token,data,android:{priority:"high",ttl:"86400s"}}}),signal:AbortSignal.timeout(10000)});
    if(!result.ok) {
     const error=await result.json().catch(()=>({}));
     const expired=error?.error?.details?.some((d:{errorCode?:string})=>d.errorCode==="UNREGISTERED");
     if(expired) invalid.push(token); else success=false;
    }
   }
  }
  await rpc("finish_push_notice",{p_id:id,p_success:success,p_invalid:invalid});
  return new Response(success?"Delivered":"Queued for retry",{status:success?200:503});
 } catch {
  if(id && /^\d+$/.test(id)) await rpc("finish_push_notice",{p_id:id,p_success:false}).catch(()=>{});
  return new Response("Queued for retry",{status:503});
 }
});
