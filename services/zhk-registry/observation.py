"""Наблюдение — единица обмена со стороной Rails.

Служба НЕ решает, что из наблюдения попадёт в справочник: это делает
Zhk::Ingest на стороне Rails (`app/services/zhk/ingest.rb`). Здесь только
форма наблюдения и её валидация — контракт, общий с
`spec/fixtures/zhk/observation_example.json` и вебхуком
`POST /webhooks/zhk_ingest`.
"""

from typing import Any, Optional

from pydantic import BaseModel, Field


class Price(BaseModel):
    """Цена одного наблюдения.

    `kind` различает происхождение величины: "from" — цена «от» с сайта
    застройщика, "median" — медиана по лотам у агрегатора. Величины
    разные по смыслу; сравнивать напрямую можно только внутри одного
    источника И одного `kind` — это решает уже Rails-сторона.
    """

    kind: str = "from"
    price_per_sqm: int
    rooms: Optional[int] = None


class Observation(BaseModel):
    source: str
    external_id: str
    name: str
    city: str
    fetched_at: str
    url: Optional[str] = None
    fields: dict[str, Any] = Field(default_factory=dict)
    price: Optional[Price] = None

    def to_payload(self) -> dict:
        """Форма, которую ждёт `POST /webhooks/zhk_ingest`.

        `exclude_none=False` — намеренно: общий образец
        (`observation_example.json`) держит `price.rooms: null` явным
        полем, а не отсутствующим ключом, и Rails-сторона на это
        рассчитывает. Опустить `None`-поля здесь значило бы разойтись с
        образцом молча.
        """
        return self.model_dump(exclude_none=False)
