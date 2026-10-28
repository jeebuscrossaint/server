// Makes Nexterm's one user and adds this server to it, the first time only.
// install.sh runs it inside the container:
//   docker exec -i -e NEXTERM_PASSWORD=... -e SERVER_USER=... -e SSH_KEY=... nexterm node --input-type=module < setup.mjs
const api = (path, body, token) =>
	fetch('http://127.0.0.1:6989/api/' + path, {
		method: body ? (path === 'identities' || path === 'entries' ? 'PUT' : 'POST') : 'GET',
		headers: { 'Content-Type': 'application/json', ...(token && { Authorization: 'Bearer ' + token }) },
		body: body && JSON.stringify(body),
	}).then(res => res.json())

// Nexterm replies 200 with a "code" when something went wrong
const check = res => {
	if (res?.code) throw new Error(res.message)
	return res
}

if (!(await api('service/is-fts'))) process.exit(0) // already set up

const { NEXTERM_PASSWORD: password, SERVER_USER: user, SSH_KEY: sshKey } = process.env
check(await api('accounts/register', { username: 'lab', password, firstName: 'lab', lastName: 'lab' }))
const { token } = check(await api('auth/login', { username: 'lab', password }))
const { id } = check(await api('identities', { name: 'server key', username: user, type: 'ssh', sshKey }, token))
check(await api('entries', {
	name: 'server',
	identities: [id],
	config: { protocol: 'ssh', ip: 'host.docker.internal', port: 22 },
}, token))
