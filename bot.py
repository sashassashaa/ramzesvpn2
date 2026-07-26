import asyncio, os, logging, json
from datetime import datetime, timedelta
from dotenv import load_dotenv
from aiogram import Bot, Dispatcher, types, F
from aiogram.filters import Command
from aiogram.types import ReplyKeyboardMarkup, KeyboardButton, InlineKeyboardButton
from aiogram.client.default import DefaultBotProperties
from aiogram.utils.keyboard import InlineKeyboardBuilder
from remnawave import RemnaWaveClient

logging.basicConfig(level=logging.INFO)
load_dotenv()

bot = Bot(token=os.getenv("BOT_TOKEN"), default=DefaultBotProperties(parse_mode="HTML"))
dp = Dispatcher()
rw = RemnaWaveClient(os.getenv("RW_API_URL"), os.getenv("RW_API_TOKEN"))

USERS_FILE = "/opt/RamzesVPN/users.json"

def load_users():
    try: return json.load(open(USERS_FILE))
    except: return {}

def save_users(u): json.dump(u, open(USERS_FILE, "w"), indent=2)

@dp.message(Command("start"))
async def start(msg: types.Message):
    kb = ReplyKeyboardMarkup(keyboard=[[KeyboardButton(text="🔗 Получить ключ")]], resize_keyboard=True)
    await msg.answer("👋 <b>Ramzes VPN</b>\n\nНажми кнопку для получения ключа", reply_markup=kb)

@dp.message(F.text == "🔗 Получить ключ")
async def get_key(msg: types.Message):
    uid = str(msg.from_user.id)
    users = load_users()
    
    if uid not in users or not users[uid].get("sub_link"):
        w = await msg.answer("🔄 Создаю ключ...")
        link, err = await rw.create_user(f"tg_{uid}", 30)
        if link:
            users[uid] = {"name": msg.from_user.full_name, "sub_link": link, "expire": (datetime.now() + timedelta(days=30)).isoformat()}
            save_users(users)
        else:
            await w.edit_text(f"❌ {err}")
            return
    
    u = users[uid]
    days = max(0, (datetime.fromisoformat(u["expire"]) - datetime.now()).days)
    
    builder = InlineKeyboardBuilder()
    builder.row(InlineKeyboardButton(text="🔄 Обновить ключ", callback_data="refresh"))
    
    await msg.answer(
        f"✅ <b>Твой ключ:</b>\n\n"
        f"🔗 <code>{u['sub_link']}</code>\n\n"
        f"📅 Срок: {days} дн.\n"
        f"📲 <i>Добавь в Inci / Hiddify / Streisand</i>",
        reply_markup=builder.as_markup()
    )

@dp.callback_query(F.data == "refresh")
async def refresh(call: types.CallbackQuery):
    uid = str(call.from_user.id)
    link, _ = await rw.create_user(f"tg_{uid}", 30)
    if link:
        users = load_users()
        users[uid] = {"name": call.from_user.full_name, "sub_link": link, "expire": (datetime.now() + timedelta(days=30)).isoformat()}
        save_users(users)
        await call.answer("✅ Обновлено!")
    await call.message.delete()
    await get_key(call.message)

async def main():
    await bot.delete_webhook(drop_pending_updates=True)
    await dp.start_polling(bot)

if __name__ == "__main__":
    asyncio.run(main())
