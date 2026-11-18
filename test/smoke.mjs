// 最小冒烟测试：不碰游戏、不发输入，只验证工具/技能注册与参数/输出形状。
import assert from 'node:assert/strict'

import * as plugin from '../index.js'

const tools = []
const skills = []
const ctx = {
  tools: { register: (tool) => tools.push(tool) },
  skills: { register: (skill) => { skills.push(skill); return () => {} } },
  effect: (fn) => { fn() },
}

plugin.apply(ctx, { windowTitle: 'Limbus', processName: 'LimbusCompany', registerSkills: true })

assert.equal(plugin.name, 'limbus-control')
assert.deepEqual(plugin.inject, ['tools'])
assert.equal(tools.length, 10, '应注册 10 个工具')
assert.equal(skills.length, 2, '应自动注册 2 个包内技能')
assert.deepEqual(skills.map((skill) => skill.name).sort(), ['limbus-daily', 'limbus-farm'])
for (const skill of skills) {
  assert.equal(typeof skill.description, 'string')
  assert.ok(skill.description.length > 0)
  assert.equal(typeof skill.content, 'string')
  assert.ok(skill.content.length > 0)
  assert.equal(skill.invocation.modelInvocable, true)
  assert.equal(skill.invocation.userInvocable, true)
}

const expected = [
  'limbus_status',
  'limbus_windows',
  'limbus_screenshot',
  'limbus_click',
  'limbus_key',
  'limbus_focus',
  'limbus_wait',
  'limbus_farm_start',
  'limbus_farm_status',
  'limbus_farm_stop',
]
assert.deepEqual(tools.map((tool) => tool.name), expected)

for (const tool of tools) {
  assert.equal(typeof tool.description, 'string')
  assert.equal(tool.parameters.type, 'object')
  assert.equal(tool.parameters.additionalProperties, false)
  assert.equal(tool.output.schema.type, 'object')
  assert.equal(typeof tool.output.render, 'function')
  assert.equal(typeof tool.execute, 'function')
}

const wait = tools.find((tool) => tool.name === 'limbus_wait')
const waited = await wait.execute({ ms: 5 }, {})
assert.equal(waited.ok, true)
assert.match(waited.text, /5 ms/)

const click = tools.find((tool) => tool.name === 'limbus_click')
await assert.rejects(() => click.execute({ x: 1.5, y: 0.5 }, {}), /0~1/)

const key = tools.find((tool) => tool.name === 'limbus_key')
await assert.rejects(() => key.execute({ key: 'not-a-key' }, {}), /不支持的按键/)

const farmStart = tools.find((tool) => tool.name === 'limbus_farm_start')
const noConfirm = await farmStart.execute({ runs: 1, confirm: false }, {})
assert.equal(noConfirm.ok, false)
assert.match(noConfirm.text, /模块/)
const zero = await farmStart.execute({ runs: 0, confirm: true }, {})
assert.equal(zero.ok, false)
assert.match(zero.text, /次数必须大于 0/)

console.log('smoke ok: 10 tools, 2 packaged skills, wait/validation/farm paths pass')
