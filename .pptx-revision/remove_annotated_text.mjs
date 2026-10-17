import fs from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const workspaceDir = 'E:/AnLuTD_Project/SD_to_Video';
const sourcePath = path.join(workspaceDir, 'presentation/FPGA音画联动音游_赛题对照版.pptx');
const buildDir = path.join(workspaceDir, '.pptx-revision');
const finalPath = path.join(workspaceDir, 'presentation/FPGA音画联动音游_赛题对照版_修订.pptx');
const skillDir = 'C:/Users/murong/.codex/plugins/cache/openai-primary-runtime/presentations/26.1007.11041/skills/presentations';
const runtimePython = 'C:/Users/murong/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe';
const { Presentation, PresentationFile } = await import('file:///C:/Users/murong/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/@oai/artifact-tool/dist/artifact_tool.mjs');

await fs.mkdir(buildDir, { recursive: true });
const presentation = await Presentation.load(sourcePath);
const copies = [
  '说明：以上“已实现”指工程 RTL / 仿真阶段；各扩展效果仍须并入最终固化版本并完成板级验收。',
  '当前差距：时序仍未闭合，未生成最终 bitstream；音游、基础功能与扩展功能的整机板级验收尚未完成。',
  '最终验收约束：指定 HX4S20C；基础项与扩展项须整合为单份固化设计，上电即可运行。当前尚未生成 bitstream，整机上板验收待完成。',
];

const hitIds = [];
const slideIds = new Set();
for (const copy of copies) {
  const found = await presentation.inspect({
    select: `$.slides[*].elements[?(@.text == '${copy.replaceAll("'", "\\'")}')]`,
    include: ['id', 'text'],
  });
  if (found.recordCount !== 1) throw new Error(`Expected one exact target for: ${copy}`);
  hitIds.push(found.records[0].id);
}
const allSlides = await presentation.inspect({
  select: '$.slides[*]', include: ['id', 'elements.id', 'elements.text'],
});
for (const slide of allSlides.records) {
  for (const element of slide.elements ?? []) if (hitIds.includes(element.id)) slideIds.add(slide.id);
}
if (slideIds.size !== 3) throw new Error(`Expected targets on three slides, found ${slideIds.size}`);

for (const slideId of slideIds) {
  const slide = presentation.resolve(slideId);
  const before = await slide.export({ format: 'png', scale: 1 });
  await fs.writeFile(path.join(buildDir, `${slideId.slice(3)}-before.png`), new Uint8Array(await before.arrayBuffer()));
}
presentation.delete(hitIds);
for (const slideId of slideIds) {
  const slide = presentation.resolve(slideId);
  const after = await slide.export({ format: 'png', scale: 1 });
  await fs.writeFile(path.join(buildDir, `${slideId.slice(3)}-after.png`), new Uint8Array(await after.arrayBuffer()));
}
const verify = await presentation.inspect({
  select: '$.slides[*].elements[*]', include: ['id', 'text'],
});
const remaining = verify.records.filter(x => copies.includes(x.text));
if (remaining.length) throw new Error('Deleted text remains in deck');

const candidatePath = path.join(buildDir, 'candidate.pptx');
await (await PresentationFile.exportPptx(presentation)).save(candidatePath);
const { finalizePresentation } = await import(pathToFileURL(path.join(skillDir, 'container_tools/artifact_tool_utils.mjs')).href);
const finalizerDir = path.join(buildDir, 'validation');
await fs.mkdir(finalizerDir, { recursive: true });
const result = await finalizePresentation({
  workspaceDir, candidatePath, finalPath, pythonExecutable: runtimePython,
  integrityValidatorPath: path.join(skillDir, 'container_tools/inspect_presentation_package_integrity.py'),
  layoutValidatorPath: path.join(skillDir, 'container_tools/inspect_presentation_layout_geometry.py'),
  layoutArgs: ['--expected-slide-size-emu', '12192000,6858000', '--validate-heading-fit'],
  requiredNativeTableOwnerSlides: [],
  fontPolicy: { basis: 'reference', families: ['Microsoft YaHei'], referencePath: sourcePath },
  verifyArtifactToolImport: true,
  receiptPath: path.join(finalizerDir, 'validation.json'),
});
await fs.writeFile(path.join(buildDir, 'result.json'), JSON.stringify({ hitIds, result }, null, 2));
console.log(JSON.stringify({ finalPath, hitIds, result }, null, 2));
