import {readFileSync, mkdirSync, copyFileSync} from 'node:fs';
import {join} from 'node:path';
const root=process.cwd();
const html=readFileSync(join(root,'public/index.html'),'utf8');
if(!html.includes('<!doctype html>')||!html.includes('Device Health')) throw Error('Invalid dashboard HTML');
mkdirSync(join(root,'dist'),{recursive:true});
copyFileSync(join(root,'public/index.html'),join(root,'dist/index.html'));
console.log('Build successful: dist/index.html');
