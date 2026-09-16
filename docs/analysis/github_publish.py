"""GitHub publishing helper; reads existing credentials without storing them."""
import json,os,subprocess,urllib.request,urllib.error

def credential():
    token=os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN')
    if token:return token
    env=dict(os.environ,GCM_INTERACTIVE='Never',GIT_TERMINAL_PROMPT='0')
    p=subprocess.run(['git','-c','credential.interactive=false','credential','fill'],input='protocol=https\nhost=github.com\n\n',capture_output=True,text=True,env=env,timeout=20)
    fields=dict(line.split('=',1) for line in p.stdout.splitlines() if '='in line)
    return fields.get('password')

def api(token,path,body=None):
    headers={'Accept':'application/vnd.github+json','Authorization':'Bearer '+token,'X-GitHub-Api-Version':'2022-11-28','User-Agent':'Codex-Stonk-Research'}
    req=urllib.request.Request('https://api.github.com'+path,data=json.dumps(body).encode() if body is not None else None,headers=headers)
    with urllib.request.urlopen(req,timeout=30) as response:return json.load(response)

def main():
    token=credential()
    if not token:print('AUTHENTICATION_REQUIRED');return
    try:
        user=api(token,'/user');print('Authenticated GitHub account:',user['login'])
        try:
            repo=api(token,'/repos/'+user['login']+'/stonk');print('Repository exists:',repo['html_url'],'private:',repo['private'])
        except urllib.error.HTTPError as e:
            if e.code==404:print('Repository does not exist yet')
            else:print('Repository lookup HTTP status:',e.code)
    except urllib.error.HTTPError as e:print('Authentication HTTP status:',e.code)

if __name__=='__main__':main()
