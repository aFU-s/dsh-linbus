// 从 DSH 会话日志估算 token 消耗分布。
// 用法：node collect-token-context.mjs <session.v4.jsonl.zstd> <out.json>
import fs from 'node:fs'
import zlib from 'node:zlib'

const [, , sessionPath, outPath] = process.argv
if (!sessionPath || !outPath) {
  console.error('usage: node collect-token-context.mjs <session.v4.jsonl.zstd> <out.json>')
  process.exit(2)
}

const lines = zlib.zstdDecompressSync(fs.readFileSync(sessionPath)).toString('utf8').split('\n').filter(Boolean)

let systemChars = 0
let histUser = 0
let histAsst = 0
let histTool = 0
let images = 0
let steps = 0
let toolCalls = 0
let outputChars = 0
let sumSystem = 0
let sumUser = 0
let sumAsst = 0
let sumTool = 0
let sumImages = 0
let sumSchema = 0
const SCHEMA_CHARS = 8000
const perStep = []

for (const line of lines) {
  let e
  try { e = JSON.parse(line) } catch { continue }

  if (e.type === 'system/message') {
    for (const b of e.data.message.content || []) if (b.type === 'text') systemChars = Math.max(systemChars, b.text.length)
  } else if (e.type === 'step/start') {
    steps++
    perStep.push(Math.round((systemChars + SCHEMA_CHARS + histUser + histAsst + histTool) / 4 + images * 1024))
    sumSystem += systemChars / 4
    sumSchema += SCHEMA_CHARS / 4
    sumUser += histUser / 4
    sumAsst += histAsst / 4
    sumTool += histTool / 4
    sumImages += images * 1024
  } else if (e.type === 'agent/inbox/spliced') {
    for (const m of e.data.inserted || []) for (const b of m.content || []) {
      if (b.type === 'text') histUser += b.text.length
      if (b.type === 'image') images++
    }
  } else if (e.type === 'assistant/message') {
    for (const b of e.data.message?.content || []) {
      if (b.type === 'text') { histAsst += b.text.length; outputChars += b.text.length }
      else if (b.type === 'reasoning') { histAsst += b.text.length; outputChars += b.text.length }
      else if (b.type === 'tool-call') { histAsst += (b.arguments || '').length; outputChars += (b.arguments || '').length; toolCalls++ }
    }
  } else if (e.type === 'tool/result') {
    for (const b of e.data.message?.content || []) {
      if (b.type === 'text') histTool += b.text.length
      if (b.type === 'image') images++
    }
  }
}

const total = sumSystem + sumSchema + sumUser + sumAsst + sumTool + sumImages
const data = {
  schemaVersion: 1,
  steps,
  toolCalls,
  images,
  systemChars,
  outputTokens: Math.round(outputChars / 4),
  total: Math.round(total),
  breakdown: {
    system: Math.round(sumSystem),
    schema: Math.round(sumSchema),
    user: Math.round(sumUser),
    assistant: Math.round(sumAsst),
    tool: Math.round(sumTool),
    images: Math.round(sumImages),
  },
  perStep,
}
fs.writeFileSync(outPath, JSON.stringify(data))
console.log(JSON.stringify({ steps, toolCalls, images, total: Math.round(total), breakdown: data.breakdown }, null, 2))
