// Builds the guest disk without Docker: Fedora arm64 base layer straight from the registry (sha256 checked), unpacked
// into a sparse ext4 image by a bootstrap microVM, then packages installed by dnf inside the VM (network via TSI).
// Usage: node prepare-guest.ts [--name guest] [--provision provision.sh] [--size 32G]
//   (needs build-host.sh first and `brew install e2fsprogs`; the disk lands in <cache>/<name>.img)
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  chmodSync,
  cpSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { parseArgs } from 'node:util';

const IMAGE = { repo: 'library/fedora', tag: '44' };
const REGISTRY = `https://registry-1.docker.io/v2/${IMAGE.repo}`;
const ACCEPT = [
  'application/vnd.oci.image.index.v1+json',
  'application/vnd.docker.distribution.manifest.list.v2+json',
  'application/vnd.oci.image.manifest.v1+json',
  'application/vnd.docker.distribution.manifest.v2+json',
].join(',');
const MKE2FS = '/opt/homebrew/opt/e2fsprogs/sbin/mke2fs';
const { values } = parseArgs({
  options: {
    size: { type: 'string', default: '32G' },
    name: { type: 'string', default: 'guest' },
    provision: { type: 'string', default: 'provision.sh' },
  },
});
const cache =
  process.env.KRUN_GAMING_CACHE ?? join(homedir(), '.local/share/krun-gaming'); // not ~/Library/Caches: macOS may purge it
const image = join(cache, `${values.name}.img`);
const layersDir = join(cache, 'layers');
const bootstrap = join(cache, 'bootstrap');
const launcher = join(
  cache,
  process.env.KRUN_GAMING_PREFIX ?? 'prefix-kosmickrisp',
  'vm-gpu',
);
const here = dirname(new URL(import.meta.url).pathname);

type Descriptor = {
  digest: string;
  size: number;
  platform?: { os: string; architecture: string };
};

async function registryGet(path: string, token: string): Promise<Response> {
  const res = await fetch(`${REGISTRY}/${path}`, {
    headers: { Authorization: `Bearer ${token}`, Accept: ACCEPT },
  });
  if (!res.ok) throw new Error(`${path}: HTTP ${res.status}`);
  return res;
}

async function downloadLayers(): Promise<void> {
  const auth = await fetch(
    `https://auth.docker.io/token?service=registry.docker.io&scope=repository:${IMAGE.repo}:pull`,
  );
  const { token } = (await auth.json()) as { token: string };
  const index = (await (
    await registryGet(`manifests/${IMAGE.tag}`, token)
  ).json()) as { manifests: Descriptor[] };
  const arm = index.manifests.find(
    (m) => m.platform?.os === 'linux' && m.platform.architecture === 'arm64',
  );
  if (!arm)
    throw new Error(`no linux/arm64 manifest for ${IMAGE.repo}:${IMAGE.tag}`);
  const manifest = (await (
    await registryGet(`manifests/${arm.digest}`, token)
  ).json()) as { layers: Descriptor[] };
  mkdirSync(layersDir, { recursive: true });
  for (const [i, layer] of manifest.layers.entries()) {
    console.log(
      `downloading ${IMAGE.repo}:${IMAGE.tag} arm64 layer ${layer.digest.slice(0, 19)} (${Math.round(layer.size / 1e6)} MB)`,
    );
    const bytes = Buffer.from(
      await (await registryGet(`blobs/${layer.digest}`, token)).arrayBuffer(),
    );
    const actual = `sha256:${createHash('sha256').update(bytes).digest('hex')}`;
    if (actual !== layer.digest)
      throw new Error(`layer hash ${actual}, registry says ${layer.digest}`);
    writeFileSync(join(layersDir, `${i}.tar`), bytes);
  }
}

function run(cmd: string, args: string[]): void {
  const r = spawnSync(cmd, args, { stdio: 'inherit' });
  if (r.status !== 0)
    throw new Error(`${cmd} ${args.join(' ')} exited with ${r.status}`);
}

function removeTree(dir: string): void {
  if (!existsSync(dir)) return;
  run('chmod', ['-R', 'u+w', dir]); // layers contain read-only directories
  rmSync(dir, { recursive: true, force: true });
}

function hostNameserver(): string {
  const conf = existsSync('/etc/resolv.conf')
    ? readFileSync('/etc/resolv.conf', 'utf8')
    : '';
  return conf.match(/^nameserver\s+(\S+)/m)?.[1] ?? '1.1.1.1';
}

function prepareBootstrap(): void {
  removeTree(bootstrap);
  mkdirSync(bootstrap, { recursive: true });
  for (const t of readdirSync(layersDir))
    run('tar', ['-xf', join(layersDir, t), '-C', bootstrap]);
  writeFileSync(
    join(bootstrap, 'etc/resolv.conf'),
    `nameserver ${hostNameserver()}\n`,
  );
  const spike = join(bootstrap, 'opt/spike');
  mkdirSync(spike, { recursive: true });
  for (const f of readdirSync(join(here, 'guest')).filter((n) =>
    n.endsWith('.sh'),
  )) {
    cpSync(join(here, 'guest', f), join(spike, f));
    chmodSync(join(spike, f), 0o755);
  }
}

function createImage(): void {
  if (!existsSync(MKE2FS))
    throw new Error(`${MKE2FS} missing: brew install e2fsprogs`);
  rmSync(image, { force: true });
  run('truncate', ['-s', values.size ?? '32G', image]); // sparse: only written blocks take space on the Mac
  run(MKE2FS, ['-q', '-t', 'ext4', '-L', 'root', image]);
}

if (!existsSync(launcher))
  throw new Error(`launcher missing: ${launcher} (run build-host.sh first)`);
await downloadLayers();
prepareBootstrap();
createImage();
run(launcher, [
  '--ram',
  '1024',
  '--vcpus',
  '2',
  '--disk',
  `root:${image}`,
  '--share',
  `layers:${layersDir}`,
  bootstrap,
  '/opt/spike/unpack.sh',
]);
removeTree(bootstrap);
rmSync(layersDir, { recursive: true, force: true });
run(launcher, [
  '--net',
  '--ram',
  '2048',
  '--vcpus',
  '4',
  '--disk',
  `root:${image}`,
  '--root-disk',
  '/dev/vda',
  '-',
  `/opt/spike/${values.provision}`,
]);
const used = spawnSync('du', ['-h', image], { encoding: 'utf8' }).stdout.split(
  '\t',
)[0];
console.log(
  `guest disk ${image}: ${used} used on the Mac (sparse, ${values.size})`,
);
