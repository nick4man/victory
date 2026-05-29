Общая информация
{clientId} - ID клиента (физические лица)
{childId} - ID ребёнка клиента (физических лиц)
{clientLegalId} - ID клиента (юридические лица)
{signerId} - ID подписанта клиентов (физических лиц)

Поля запроса реквизита физического лица
```
         Поле          Тип                Ограничения / Формат            Обязательность
firstname            string    До 200 символов                            Да

firstname_decline    boolean   Склонение имени                            Нет

lastname             string    До 200 символов nullable                   Нет

lastname_decline     boolean   Склонение фамилии                          Нет

fathername           string    До 200 символов nullable                   Нет

fathername_decline   boolean   Склонение отчества                         Нет

no_fathername        boolean   Отсутствие отчества                        Нет

birthdate            string    Формат YYYY-MM-DD nullable                 Нет

                               Допустимые значения: male, female
gender               string                                               Нет
                               nullable

                               РФ — ровно 12 цифр. Иностранцы — до 20
inn                  string                                               Нет
                               любых символов nullable

kpp                  string    Ровно 9 цифр nullable                      Нет

settlement_account   string    Ровно 20 цифр nullable                     Нет

bank                 string    До 200 символов nullable                   Нет

corr_account         string    Ровно 20 цифр, начинается с 301 nullable   Нет

bank_bic             string    Ровно 9 цифр nullable                      Нет

is_self_employment   boolean   Признак самозанятого                       Нет

snils                string    Ровно 11 цифр nullable                     Нет

job_place            string    До 200 символов nullable                   Нет

                               Допустимые значения: marriage, divorced,
marital_status       string                                               Нет
                               single nullable

living_place         string    До 500 символов nullable                   Нет

            Поле             Тип                      Ограничения / Формат             Обязательность
```
comment                    string         До 500 символов nullable                     Нет

nationality                string         0 — иностранец, 1 — гражданин РФ             Да

nationality_country        string         До 100 символов nullable                     Нет

birthplace                 string         До 200 символов nullable                     Нет

```
                                         РФ — ровно 4 символа. Иностранцы — до 6
```
series                     string                                                      Да
```
                                         символов

                                         РФ — ровно 6 символов. Иностранцы — до 10
```
number                     string                                                      Да
```
                                         символов
```
issued_by                  string         До 1000 символов nullable                    Нет

issue_date                 string         Формат YYYY-MM-DD nullable                   Нет

```
                                         Код подразделения (для РФ). Формат 000000
```
code                       string                                                      Нет
```
                                         nullable
```
no_registration            boolean        Признак отсутствия регистрации               Нет

permanent_registration     string         До 500 символов, nullable                    Нет

temporary_registration     string         До 500 символов, nullable                    Нет

emails                     array          Массив с email-адресами nullable             Нет

phones                     array          Массив с телефонами nullable                 Нет

```
                                         Тип сущности, 2 - объекты, 3 - заявки, 4 -
```
entity_type                string                                                      Да
```
                                         услуги
```
entity_id                  int            Идентификатор сущности                       Да


Поля запроса реквизита ребенка (свидетельство о рождении,
остальные поля аналогичны полям реквизита ФЛ)
```
             Поле                  Тип                 Ограничения / Формат           Обязательность
```
birth_act_number                 string       До 200 символов. nullable                Нет

birth_certificate_number         string       До 200 символов. nullable                Нет

country                          string       До 100 символов. nullable                Нет

father_fathername                string       До 200 символов. nullable                Нет

father_fathername_decline        boolean      Склонение отчества отца                  Нет

father_firstname                 string       До 200 символов. nullable                Нет



```
           Поле                Тип              Ограничения / Формат          Обязательность
```
father_firstname_decline     boolean   Склонение имени отца                   Нет

father_lastname              string    До 200 символов. nullable              Нет

father_lastname_decline      boolean   Склонение фамилии отца                 Нет

father_no_fathername         boolean   Признак отсутствия отчества у отца     Нет

father_not_detected          boolean   Признак отсутствия данных об отце      Нет

mother_fathername            string    До 200 символов. nullable              Нет

mother_fathername_decline boolean      Склонение отчества матери              Нет

mother_firstname             string    До 200 символов. nullable              Нет

mother_firstname_decline     boolean   Склонение имени матери                 Нет

mother_lastname              string    До 200 символов. nullable              Нет

mother_lastname_decline      boolean   Склонение фамилии матери               Нет

mother_no_fathername         boolean   Признак отсутствия отчества у матери   Нет

```
                                      Дата регистрации рождения. Формат
```
registration_date            string                                           Нет
```
                                      YYYY-MM-DD. nullable
```
registration_place           string    До 200 символов. nullable              Нет


Поля запроса реквизита юридического лица
```
          Поле                Тип              Ограничения / Формат          Обязательность
```
actual_address               string    До 500 символов. nullable              Нет

bank                         string    До 200 символов. nullable              Нет

bank_bic                     string    Ровно 9 цифр. nullable                 Нет

```
                                      Ровно 20 цифр. Должен начинаться с
```
corr_account                 string                                           Нет
```
                                      301. nullable
```
director_fathername          string    До 200 символов. nullable              Нет

```
                                      Склонение отчества директора.
```
director_fathername_decline boolean                                           Нет
```
                                      nullable
```
director_firstname           string    До 200 символов. nullable              Нет

director_firstname_decline   boolean   Склонение имени директора. nullable    Нет

director_lastname            string    До 200 символов. nullable              Нет




```
                                         Склонение фамилии директора.
```
director_lastname_decline      boolean                                         Нет
```
                                        nullable

                                        Признак отсутствия отчества у
```
director_no_fathername         boolean                                         Нет
```
                                        директора. nullable
```
entity_id                      int       Идентификатор сущности                Да

```
                                        Тип сущности (например, company,
```
entity_type                    string                                          Да
```
                                        sole_proprietor)
```
inn                            string    ЮЛ — до 10 цифр. ИП — до 12 цифр.     Да

is_self_employment             boolean   Признак самозанятости                 Нет

kpp                            string    Ровно 9 цифр. nullable                Нет

legal_address                  string    До 500 символов. nullable             Нет

legal_name                     string    До 200 символов. nullable             Нет

```
                                        Организационно-правовая форма
```
legal_type                     string                                          Да
```
                                        (OOO, AO, IP, ZAO, OAO, PAO)
```
ogrn                           string    От 13 до 15 символов. nullable        Нет

phones                         array     Массив строк с телефонами. nullable   Нет

```
                                        Массив строк с email-адресами.
```
emails                         array                                           Нет
```
                                        nullable

                                        Только для ИП. Формат YYYY-MM-DD.
```
registration_date              string                                          Нет
```
                                        nullable
```
settlement_account             string    Ровно 20 цифр. nullable               Нет


Поля запроса реквизита подписанта
```
        Поле          Тип                    Ограничения / Формат             Обязательность
```
act_date             string     Формат YYYY-MM-DD. nullable                    Нет

act_date_limit       string     Формат YYYY-MM-DD. nullable                    Нет

act_number           string     До 100 символов. nullable                      Нет

entity_id            int        Идентификатор сущности                         Да

fathername           string     До 200 символов. nullable                      Нет

fathername_decline   boolean    Склонение отчества                             Нет

finance_limit        string     Тип string                                     Нет




```
          Поле         Тип                  Ограничения / Формат                Обязательность
firstname           string    До 200 символов                                  Да

firstname_decline   boolean   Склонение имени                                  Нет

gender              string    Допустимые значения: male, female                Да

lastname            string    До 200 символов. nullable                        Нет

lastname_decline    boolean   Склонение фамилии                                Нет

no_fathername       boolean   Признак отсутствия отчества                      Нет

position            string    До 200 символов. nullable                        Нет

                              charter - устав, attorney - доверенность,
position_by_act     string    notarial_attorney - нотариальная доверенность,   Да
                              order - приказ, certificate - свидетельство
```
## 1. Клиенты (физические лица) - Получение списка
URL:
POST https://agencies-p.topnlab.ru/public/clients/get-by-entity
Тело запроса:

```
{
    "key": "asd", // ключ партнера
    "entity_id": 7023381, // ID карточки с реквизитом
    "entity_type": 3 // тип карточки (продавец, арендодатель,
покупатель, арендатор, услуга). 2 - объекты, 3 - заявки, 4 - услуги
}
```
Ответ:

```
{
    "status": "success",
    "data": {
        "clients": [ // Список клиентов (физические лица)
            {
                "id": 2214, // ID клиента
                "parent_id": null,
                "company_id": 936, // ID компании, к которой привязан
клиент
                "firstname": "Иван", // Имя клиента
                "firstname_decline": true, // Признак склонения имени
                "lastname": "Иванов", // Фамилия клиента
                "lastname_decline": true, // Признак склонения фамилии
                "fathername": "Иванович", // Отчество клиента

                 "fathername_decline": true, // Признак склонения
```
отчества
```
                "no_fathername": false, // Флаг отсутствия отчества
                "birthdate": "1986-09-05", // Дата рождения
                "gender": "female", // Пол
                "inn": "546546546546", // ИНН
                "kpp": "111111111", // КПП
                "settlement_account": "54156456456456465465", //
```
Расчетный счет
```
               "bank": "Сбербанк", // Банк клиента
               "corr_account": "30111111111111111111", //
```
Корреспондентский счет
```
               "bank_bic": "000000000", // БИК банка
               "is_self_employment": false, // Признак самозанятости
               "snils": "56456465456", // СНИЛС
               "job_place": "Место работы", // Место работы
               "marital_status": "divorced", // Семейное положение
               "living_place": "Адрес фактического проживания", //
```
Фактический адрес
```
               "comment": "Примечание", // Дополнительный комментарий
               "created_at": "2025-09-17 16:22:25", // Дата создания
```
записи
```
               "updated_at": "2025-09-17 16:22:25", // Дата обновления
```
записи
```
               "deleted_at": null, // Дата удаления (если удалён)
               "children": [ // Дети клиента
                   {
                       "id": 379, // ID ребенка
                       "parent_id": null,
                       "client_id": 2214, // ID клиента-родителя
                       "firstname": "Имя", // Имя ребенка
                       "firstname_decline": true, // Склонение имени
                       "lastname": "Фамилия", // Фамилия ребенка
                       "lastname_decline": true, // Склонение фамилии
                       "fathername": "Отчество", // Отчество ребенка
                       "fathername_decline": true, // Склонение
```
отчества
```
                       "no_fathername": false, // Флаг отсутствия
```
отчества
```
                       "birthdate": "2025-09-17", // Дата рождения
                       "gender": "female", // Пол
                       "inn": null, // ИНН
                       "snils": "22222222222", // СНИЛС
                       "comment": "Примечание", // Комментарий
                       "created_at": "2025-09-17 16:35:52", // Дата
```
создания
```
                       "updated_at": "2025-09-17 18:02:11", // Дата

обновления
                       "deleted_at": null, // Дата удаления
                       "passport": { // Паспорт ребенка
                           "id": 2606, // ID паспорта
                           "parent_id": null,
                           "company_id": 936,
                           "client_type":
```
"App\\Models\\Client\\Client",
```
                           "client_id": null,
                           "child_id": 379,
                           "nationality": "1", // Национальность
                           "nationality_country": null, // Страна
```
гражданства
```
                           "birthplace": "Место рождения", // Место
```
рождения
```
                           "series": "4515", // Серия паспорта
                           "number": "512512", // Номер паспорта
                           "issued_by": "Кем выдан", // Орган, выдавший
```
паспорт
```
                           "issue_date": "2025-09-17", // Дата выдачи
                           "code": "222222", // Код подразделения
                           "no_registration": 0, // Признак отсутствия
```
регистрации
```
                           "permanent_registration": "Постоянная
```
регистрация", // Постоянная регистрация
```
                           "temporary_registration": "Временная
```
регистрация", // Временная регистрация
```
                           "created_at": "2025-09-17 16:35:52",
                           "updated_at": "2025-09-17 16:35:52",
                           "deleted_at": null,
                           "hashes": [] // Хэши документов
                       },
                       "birth_certificate": null, // Свидетельство о
```
рождении (если есть)
```
                       "company_id": 936 // Компания
                    },
                    {
                       "id": 381, // ID второго ребенка
                       "parent_id": null,
                       "client_id": 2214,
                       "firstname": "Имя",
                       "firstname_decline": true,
                       "lastname": "Фамилия",
                       "lastname_decline": true,
                       "fathername": "Отчество",
                       "fathername_decline": true,
                       "no_fathername": false,

                        "birthdate": "2025-09-17",
                       "gender": "female",
                       "inn": null,
                       "snils": "22222222222",
                       "comment": "Примечание",
                       "created_at": "2025-09-17 17:41:32",
                       "updated_at": "2025-09-17 17:41:32",
                       "deleted_at": null,
                       "passport": { // Паспортные данные второго
```
ребенка
```
                           "id": 2610,
                           "parent_id": null,
                           "company_id": 936,
                           "client_type":
```
"App\\Models\\Client\\Client",
```
                           "client_id": null,
                           "child_id": 381,
                           "nationality": "1",
                           "nationality_country": null,
                           "birthplace": "Место рождения",
                           "series": "4515",
                           "number": "512512",
                           "issued_by": "Кем выдан",
                           "issue_date": "2025-09-17",
                           "code": "222222",
                           "no_registration": 0,
                           "permanent_registration": "Постоянная
```
регистрация",
```
                           "temporary_registration": "Временная
```
регистрация",
```
                           "created_at": "2025-09-17 17:41:32",
                           "updated_at": "2025-09-17 17:41:32",
                           "deleted_at": null,
                           "hashes": []
                       },
                       "birth_certificate": null,
                       "company_id": 936
                   }
               ],
               "passport": { // Паспорт клиента
                   "id": 2496, // уникальный идентификатор паспорта
                   "parent_id": null,
                   "company_id": 936,
                   "client_type": "App\\Models\\Client\\Client",
                   "client_id": 2149, // идентификатор клиента
                   "child_id": null,
                   "nationality": "1", // гражданство

                     "nationality_country": null, // страна гражданства
                    "birthplace": "Место рождения", // место рождения
                    "series": "4125", // серия паспорта
                    "number": "125151", // номер паспорта
                    "issued_by": "Кем выдан", // кем выдан паспорт
                    "issue_date": "2025-09-17", // дата выдачи
                    "code": "290001", // код подразделения
                    "no_registration": 0, // признак отсутствия
регистрации
                     "permanent_registration": "Постоянная регистрация",
// постоянная регистрация
                     "temporary_registration": "Временная регистрация",
// временная регистрация
                     "created_at": "2025-09-04 15:37:39", // дата
создания
                     "updated_at": "2025-09-04 15:38:35", // дата
обновления
                     "deleted_at": null,
                     "hashes": [] // хэш фото паспорта
                 },
                 "client_entities": [ // Привязки клиента к юр. лицам
                     {
                         "id": 5466,
                         "company_id": 936,
                         "client_id": 2214,
                         "client_legal_id": null,
                         "entity_type": 2, // Тип сущности (юридическое
лицо)
                         "entity_id": 47894422 // ID юр. лица
                     }
                 ],
                 "emails": [], // Список email-адресов клиента
                 "phones": [] // Список телефонов клиента
             }
         ],
         "client_legals": [] // Список юр. лиц
    }
}
```
## 2. Клиенты (физические лица) - получение по ID
URL: GET https://agencies-p.topnlab.ru/public/clients/{clientId}?key=asd
Ответ:




```
{
   "status": "success",
   "data":{
                "id": 2149, // уникальный идентификатор клиента
                "parent_id": null,
                "company_id": 936,
                "firstname": "Иван", // имя клиента
                "firstname_decline": true, // признак склонения имени
                "lastname": "Иванов", // фамилия клиента
                "lastname_decline": true, // признак склонения фамилии
                "fathername": "Иванович", // отчество клиента
                "fathername_decline": true, // признак склонения
```
отчества
```
                "no_fathername": false, // флаг отсутствия отчества
                "birthdate": "1986-09-05", // дата рождения
                "gender": "female", // пол клиента
                "inn": "546546546546", // ИНН клиента
                "kpp": "111111111", // КПП (для организаций)
                "settlement_account": "54156456456456465465", //
```
расчетный счет
```
                "bank": "Банк клиента", // банк, где открыт счет
                "corr_account": "30111111111111111111", //
```
корреспондентский счет
```
                "bank_bic": "000000000", // БИК банка
                "is_self_employment": false, // самозанятый или нет
                "snils": "56456465456", // СНИЛС клиента
                "job_place": "Место работы", // место работы
                "marital_status": "divorced", // семейное положение
                "living_place": "Адрес фактического проживания", //
```
адрес проживания
```
                "comment": "Примечание", // примечание по клиенту
                "created_at": "2025-09-04 15:37:39", // дата создания
                "updated_at": "2025-09-04 15:37:39", // дата обновления
                "deleted_at": null,
                "children": [], // список детей клиента
                "passport": {
                    "id": 2496, // уникальный идентификатор паспорта
                    "parent_id": null,
                    "company_id": 936,
                    "client_type": "App\\Models\\Client\\Client",
                    "client_id": 2149, // идентификатор клиента
                    "child_id": null,
                    "nationality": "1", // гражданство
                    "nationality_country": null, // страна гражданства
                    "birthplace": "Место рождения", // место рождения
                    "series": "4125", // серия паспорта
                    "number": "125151", // номер паспорта

                     "issued_by": "Кем выдан", // кем выдан паспорт
                    "issue_date": "2025-09-17", // дата выдачи
                    "code": "290001", // код подразделения
                    "no_registration": 0, // признак отсутствия
регистрации
                    "permanent_registration": "Постоянная регистрация",
// постоянная регистрация
                    "temporary_registration": "Временная регистрация",
// временная регистрация
                    "created_at": "2025-09-04 15:37:39", // дата
создания
                    "updated_at": "2025-09-04 15:38:35", // дата
обновления
                    "deleted_at": null,
                    "hashes": [] // хэш фото паспорта
                },
                "client_entities": [
                    {
                         "id": 5385,
                         "company_id": 936,
                         "client_id": 2149,
                         "client_legal_id": null,
                         "entity_type": 3,
                         "entity_id": 7023381
                    }
                ],
                "emails": [],
                "phones": [
                    {
                         "phone": "3333333333" // номер телефона
                    }
                ]
}
```
## 3. Клиенты (физические лица) - Создание
URL: POST https://agencies-p.topnlab.ru/public/clients
Тело запроса:

```
{
    "key": "asd", // ключ партнера, обязательное поле
    "entity_id": 7023381, // идентификатор карточки, к которой крепится
реквизит, обязательное поле
    "entity_type": 3 // тип карточки (продавец, арендодатель,

покупатель, арендатор, услуга).
   "parent_id": null,
   "firstname": "Иван", // имя клиента, обязательное поле
   "firstname_decline": true, // признак склонения имени
   "lastname": "Иванов", // фамилия клиента
   "lastname_decline": true, // признак склонения фамилии
   "fathername": "Иванович", // отчество клиента
   "fathername_decline": true, // признак склонения отчества
   "no_fathername": false, // флаг отсутствия отчества
   "birthdate": "1986-09-05", // дата рождения
   "gender": "female", // пол клиента (например: male/female)
   "inn": "546546546546", // ИНН клиента
   "kpp": "111111111", // КПП
   "settlement_account": "54156456456456465465", // расчетный счет
   "bank": "Сбербанк", // Название банка
   "corr_account": "30111111111111111111", // корреспондентский счет
   "bank_bic": "000000000", // БИК банка
   "is_self_employment": false, // самозанятый или нет
   "snils": "56456465456", // СНИЛС
   "job_place": "Место работы", // место работы
   "marital_status": "divorced", // семейное положение
   "living_place": "Адрес фактического проживания", // адрес проживания
   "comment": "Примечание", // примечание по клиенту
   "passport": { // паспортные данные
       "nationality": "1", // гражданство (например, код страны)
       "nationality_country": null, // страна гражданства
       "birthplace": "Место рождения", // место рождения
       "series": "3333", // серия паспорта
       "number": "512512", // номер паспорта
       "issued_by": "Кем выдан", // кем выдан паспорт
       "issue_date": "2025-09-17", // дата выдачи
       "code": "290001", // код подразделения
       "no_registration": 0, // признак отсутствия регистрации
       "permanent_registration": "Постоянная регистрация", //
```
постоянная регистрация
```
       "temporary_registration": "Временная регистрация" // временная
```
регистрация
```
   },
   "emails": [], // список email клиента
   "phones": [], // список телефонов клиента
   "children": [], // список детей клиента (если есть)
   "client_entities": [
       {
           "client_legal_id": null, // идентификатор юр. лица (если
```
есть)
```
           "entity_type": 3, // тип карточки
           "entity_id": 7023381 // идентификатор карточки, к которой

 крепится реквизит
        }
    ]
}
```
Ответ:

```
{
        "status": "success",
        "data": {
            "firstname": "Иван",
            "firstname_decline": true,
            "lastname": "Иванов",
            "lastname_decline": true,
            "fathername": "Иванович",
            "fathername_decline": true,
            "no_fathername": false,
            "birthdate": "1986-09-05",
            "gender": "female",
            "inn": "546546546546",
            "kpp": "111111111",
            "settlement_account": "54156456456456465465",
            "bank": "Сбербанк",
            "corr_account": "30111111111111111111",
            "bank_bic": "000000000",
            "is_self_employment": false,
            "snils": "56456465456",
            "job_place": "Место работы",
            "marital_status": "divorced",
            "living_place": "Адрес фактического проживания",
            "comment": "Примечание",
            "company_id": 936,
            "updated_at": "2025-09-17 16:22:25",
            "created_at": "2025-09-17 16:22:25",
            "id": 2214,
            "phones": [],
            "emails": []
        }
}
```
## 4. Клиенты (физические лица) - Обновление
URL: PUT|PATCH https://agencies-p.topnlab.ru/public/clients/{clientId}
Тело запроса:



```
{
   "key": "asd", // ключ партнера, обязательное поле
   "entity_id": 47894422, // идентификатор карточки, к которой крепится
```
реквизит, обязательное поле
```
   "entity_type": 2,
   "parent_id": null,
   "firstname": "Иван", // имя клиента, обязательное поле
   "firstname_decline": true, // признак склонения имени
   "lastname": "Иванов", // фамилия клиента
   "lastname_decline": true, // признак склонения фамилии
   "fathername": "Иванович", // отчество клиента
   "fathername_decline": true, // признак склонения отчества
   "no_fathername": false, // флаг отсутствия отчества
   "birthdate": "1986-09-05", // дата рождения
   "gender": "female", // пол клиента (например: male/female)
   "inn": "546546546546", // ИНН клиента
   "kpp": "111111111", // КПП
   "settlement_account": "54156456456456465465", // расчетный счет
   "bank": "Сбербанк", // Название банка
   "corr_account": "30111111111111111111", // корреспондентский счет
   "bank_bic": "000000000", // БИК банка
   "is_self_employment": false, // самозанятый или нет
   "snils": "56456465456", // СНИЛС
   "job_place": "Место работы", // место работы
   "marital_status": "divorced", // семейное положение
   "living_place": "Адрес фактического проживания", // адрес проживания
   "comment": "Примечание", // примечание по клиенту
   "passport": { // паспортные данные
       "id": 2601,
       "nationality": "1", // гражданство (например, код страны)
       "nationality_country": null, // страна гражданства
       "birthplace": null, // место рождения
       "series": "3333", // серия паспорта
       "number": "512512", // номер паспорта
       "issued_by": null, // кем выдан паспорт
       "issue_date": null, // дата выдачи
       "code": null, // код подразделения
       "no_registration": 0, // признак отсутствия регистрации
       "permanent_registration": null, // постоянная регистрация
       "temporary_registration": null // временная регистрация
   },
   "emails": [], // список email клиента
   "phones": [], // список телефонов клиента
   "children": [], // список детей клиента (если есть)
   "client_entities": [
       {
           "client_id": 2214,

                 "client_legal_id": null, // идентификатор юр. лица (если
есть)
            "entity_type": 2, // тип карточки
            "entity_id": 47894422 // идентификатор карточки, к которой
крепится реквизит
        }
    ]
}
```
Ответ:

```
{
        "status": "success",
        "data": {
            "id": 2214,
            "parent_id": null,
            "company_id": 936,
            "firstname": "Иван",
            "firstname_decline": true,
            "lastname": "Иванов",
            "lastname_decline": true,
            "fathername": "Иванович",
            "fathername_decline": true,
            "no_fathername": false,
            "birthdate": "1986-09-05",
            "gender": "female",
            "inn": "546546546546",
            "kpp": "111111111",
            "settlement_account": "54156456456456465465",
            "bank": "Сбербанк",
            "corr_account": "30111111111111111111",
            "bank_bic": "000000000",
            "is_self_employment": false,
            "snils": "56456465456",
            "job_place": "Место работы",
            "marital_status": "divorced",
            "living_place": "Адрес фактического проживания",
            "comment": "Примечание",
            "created_at": "2025-09-17 16:22:25",
            "updated_at": "2025-09-17 16:22:25",
            "deleted_at": null,
            "passport": {
                "id": 2601,
                "parent_id": null,
                "company_id": 936,
                "client_type": "App\\Models\\Client\\Client",
                "client_id": 2214,

             "child_id": null,
            "nationality": "1",
            "nationality_country": null,
            "birthplace": null,
            "series": "3333",
            "number": "512512",
            "issued_by": null,
            "issue_date": null,
            "code": "",
            "no_registration": 0,
            "permanent_registration": null,
            "temporary_registration": null,
            "created_at": "2025-09-17 16:22:25",
            "updated_at": "2025-09-17 16:33:03",
            "deleted_at": null,
            "hashes": []
        },
        "phones": [],
        "emails": []
    }
}
```
## 5. Дети клиентов (физических лиц) - Получение
URL: GET
https://agencies-p.topnlab.ru/public/clients/{clientId}/children/{childId}
?key=asd
Ответ:

```
{
    "id": 379, // ID записи (уникальный идентификатор ребёнка)
    "parent_id": null,
    "client_id": 2214, // ID клиента, к которому привязан ребёнок
    "firstname": "Имя", // Имя ребёнка
    "firstname_decline": true, // Признак склонения имени
    "lastname": "Фамилия", // Фамилия ребёнка
    "lastname_decline": true, // Признак склонения фамилии
    "fathername": "Отчество", // Отчество ребёнка
    "fathername_decline": true, // Признак склонения отчества
    "no_fathername": false, // Флаг отсутствия отчества
    "birthdate": "2025-09-17", // Дата рождения
    "gender": "female", // Пол (male / female)
    "inn": null, // ИНН (если есть)
    "snils": "22222222222", // СНИЛС ребёнка
    "comment": "Примечание", // Дополнительный комментарий

    "created_at": "2025-09-17 16:35:52", // Дата и время создания записи
   "updated_at": "2025-09-17 16:35:52", // Дата и время последнего
```
обновления записи
```
   "deleted_at": null, // Дата удаления (если запись удалена)
   "passport": { // Данные паспорта
        "id": 2606, // ID паспорта
        "parent_id": null,
        "company_id": 936, // ID компании
        "client_type": "App\\Models\\Client\\Client",
        "client_id": null,
        "child_id": 379, // ID ребёнка
        "nationality": "1", // Гражданство
        "nationality_country": null, // Страна гражданства
        "birthplace": "Место рождения", // Место рождения
        "series": "4515", // Серия паспорта
        "number": "512512", // Номер паспорта
        "issued_by": "Кем выдан", // Орган, выдавший паспорт
        "issue_date": "2025-09-17", // Дата выдачи паспорта
        "code": "222222", // Код подразделения
        "no_registration": 0, // Признак отсутствия регистрации (0/1)
        "permanent_registration": "Постоянная регистрация", // Адрес
```
постоянной регистрации
```
        "temporary_registration": "Временная регистрация", // Адрес
```
временной регистрации
```
        "created_at": "2025-09-17 16:35:52", // Дата и время создания
```
паспорта
```
        "updated_at": "2025-09-17 16:35:52", // Дата и время обновления
```
паспорта
```
        "deleted_at": null, // Дата удаления паспорта (если удалён)
        "hashes": [] // Хэши данных паспорта
   }
```
}
```
   "birth_certificate": null,
   "client": { // данные родителя
        "id": 2214,
        "parent_id": null,
        "company_id": 936,
        "firstname": "Иван",
        "firstname_decline": true,
        "lastname": "Иванов",
        "lastname_decline": true,
        "fathername": "Иванович",
        "fathername_decline": true,
        "no_fathername": false,
        "birthdate": "1986-09-05",
        "gender": "female",
        "inn": "546546546546",

         "kpp": "111111111",
        "settlement_account": "54156456456456465465",
        "bank": "Сбербанк",
        "corr_account": "30111111111111111111",
        "bank_bic": "000000000",
        "is_self_employment": false,
        "snils": "56456465456",
        "job_place": "Место работы",
        "marital_status": "divorced",
        "living_place": "Адрес фактического проживания",
        "comment": "Примечание",
        "created_at": "2025-09-17 16:22:25",
        "updated_at": "2025-09-17 16:22:25",
        "deleted_at": null
    },
    "company_id": 936

}
```
## 6. Дети клиентов (физических лиц) - Создание
URL:
POST https://agencies-p.topnlab.ru/public/clients/{clientId}/children
Тело запроса:

```
{
    "key": "asd",
    "parent_id": null,
    "entity_id": "47894422",
    "entity_type": 2,
    "client_id": 2214, // ID клиента, к которому привязан ребёнок
    "firstname": "Имя", // Имя ребёнка
    "firstname_decline": true, // Признак склонения имени
    "lastname": "Фамилия", // Фамилия ребёнка
    "lastname_decline": true, // Признак склонения фамилии
    "fathername": "Отчество", // Отчество ребёнка
    "fathername_decline": true, // Признак склонения отчества
    "no_fathername": false, // Флаг отсутствия отчества
    "birthdate": "2025-09-17", // Дата рождения
    "gender": "female", // Пол (male / female)
    "inn": null, // ИНН
    "snils": "22222222222", // СНИЛС
    "comment": "Примечание", // Дополнительный комментарий
    "deleted_at": null, // Дата удаления (если запись удалена)
    "passport": { // Данные паспорта

          "client_type": "App\\Models\\Client\\Client",
         "client_id": null,
         "nationality": "1", // Гражданство
         "nationality_country": null, // Страна гражданства
         "birthplace": "Место рождения", // Место рождения
         "series": "4515", // Серия паспорта
         "number": "512512", // Номер паспорта
         "issued_by": "Кем выдан", // Орган, выдавший паспорт
         "issue_date": "2025-09-17", // Дата выдачи паспорта
         "code": "222222", // Код подразделения
         "no_registration": 0, // Признак отсутствия регистрации (0/1)
         "permanent_registration": "Постоянная регистрация", // Адрес
постоянной регистрации
         "temporary_registration": "Временная регистрация", // Адрес
временной регистрации
         "created_at": "2025-09-17 16:35:52", // Дата и время создания
паспорта
         "updated_at": "2025-09-17 16:35:52", // Дата и время обновления
паспорта
         "deleted_at": null, // Дата удаления паспорта (если удалён)
         "hashes": null // Хэши данных паспорта
    }
}
```
Ответ:

```
{
        "status": "success",
        "data": {
            "parent_id": null,
            "client_id": 2214,
            "firstname": "Имя",
            "firstname_decline": true,
            "lastname": "Фамилия",
            "lastname_decline": true,
            "fathername": "Отчество",
            "fathername_decline": true,
            "no_fathername": false,
            "birthdate": "2025-09-17",
            "gender": "female",
            "inn": null,
            "snils": "22222222222",
            "comment": "Примечание",
            "updated_at": "2025-09-17 17:41:32",
            "created_at": "2025-09-17 17:41:32",
            "id": 381
        }

 }
```
## 7. Дети клиентов (физических лиц) - Обновление
URL: PUT|PATCH
https://agencies-p.topnlab.ru/public/clients/{clientId}/children/{childId}
Тело запроса:

```
{
    "key": "asd",
    "parent_id": null,
    "entity_id": "47894422",
    "entity_type": 2,
    "client_id": 2214, // ID клиента, к которому привязан ребёнок
    "firstname": "Имя", // Имя ребёнка
    "firstname_decline": true, // Признак склонения имени
    "lastname": "Фамилия", // Фамилия ребёнка
    "lastname_decline": true, // Признак склонения фамилии
    "fathername": "Отчество", // Отчество ребёнка
    "fathername_decline": true, // Признак склонения отчества
    "no_fathername": false, // Флаг отсутствия отчества
    "birthdate": "2025-09-17", // Дата рождения
    "gender": "female", // Пол (male / female)
    "inn": null, // ИНН (если есть)
    "snils": "22222222222", // СНИЛС ребёнка
    "comment": "Примечание", // Дополнительный комментарий
    "deleted_at": null, // Дата удаления (если запись удалена)
    "passport": { // Данные паспорта
        "client_type": "App\\Models\\Client\\Client",
        "client_id": null,
        "nationality": "1", // Гражданство
        "nationality_country": null, // Страна гражданства
        "birthplace": "Место рождения", // Место рождения
        "series": "4515", // Серия паспорта
        "number": "512512", // Номер паспорта
        "issued_by": "Кем выдан", // Орган, выдавший паспорт
        "issue_date": "2025-09-17", // Дата выдачи паспорта
        "code": "222222", // Код подразделения
        "no_registration": 0, // Признак отсутствия регистрации (0/1)
        "permanent_registration": "Постоянная регистрация", // Адрес
постоянной регистрации
        "temporary_registration": "Временная регистрация", // Адрес
временной регистрации
        "deleted_at": null, // Дата удаления паспорта (если удалён)
        "hashes": null // Хэши данных паспорта

         }
}
```
Ответ:

```
{
        "status": "success",
        "data": {
            "id": 379,
            "parent_id": null,
            "client_id": 2214,
            "firstname": "Имя",
            "firstname_decline": true,
            "lastname": "Фамилия1",
            "lastname_decline": true,
            "fathername": "Отчество",
            "fathername_decline": true,
            "no_fathername": false,
            "birthdate": "2025-09-17",
            "gender": "female",
            "inn": null,
            "snils": "22222222222",
            "comment": "Примечание",
            "created_at": "2025-09-17 16:35:52",
            "updated_at": "2025-09-17 17:53:28",
            "deleted_at": null,
            "passport": {
                "id": 2606,
                "parent_id": null,
                "company_id": 936,
                "client_type": "App\\Models\\Client\\Client",
                "client_id": null,
                "child_id": 379,
                "nationality": "1",
                "nationality_country": null,
                "birthplace": "Место рождения",
                "series": "4515",
                "number": "512512",
                "issued_by": "Кем выдан",
                "issue_date": "2025-09-17",
                "code": "222222",
                "no_registration": 0,
                "permanent_registration": "Постоянная регистрация",
                "temporary_registration": "Временная регистрация",
                "created_at": "2025-09-17 16:35:52",
                "updated_at": "2025-09-17 16:35:52",
                "deleted_at": null,

             "hashes": []
        },
        "birth_certificate": null,
        "client": {
            "id": 2214,
            "parent_id": null,
            "company_id": 936,
            "firstname": "Иван",
            "firstname_decline": true,
            "lastname": "Иванов",
            "lastname_decline": true,
            "fathername": "Иванович",
            "fathername_decline": true,
            "no_fathername": false,
            "birthdate": "1986-09-05",
            "gender": "female",
            "inn": "546546546546",
            "kpp": "111111111",
            "settlement_account": "54156456456456465465",
            "bank": "Сбербанк",
            "corr_account": "30111111111111111111",
            "bank_bic": "000000000",
            "is_self_employment": false,
            "snils": "56456465456",
            "job_place": "Место работы",
            "marital_status": "divorced",
            "living_place": "Адрес фактического проживания",
            "comment": "Примечание",
            "created_at": "2025-09-17 16:22:25",
            "updated_at": "2025-09-17 16:22:25",
            "deleted_at": null
        },
        "company_id": 936,
    }
}
```
## 8. Клиенты (юридические лица) - Создание
URL: POST https://agencies-p.topnlab.ru/public/client-legals
Тело запроса:

```
{
    "key": "asd", // ключ партнера
    "entity_id": 47894422, // ID сущности

     "entity_type": 2, // Тип сущности
    "registration_date": "2025-09-17", // Дата регистрации организации
```
ИП
```
   "birthdate": "1998-09-03", // Дата рождения (актуально для ИП)
   "legal_name": null, // Полное юридическое название (если есть)
   "legal_type": "ip", // Тип юр. лица (например: ooo, ao, ip)
   "legal_address": "Юридический адрес", // Юридический адрес
   "actual_address": "Фактический адрес", // Фактический адрес
   "ogrn": "111111111111111", // ОГРН
   "inn": "405881403100", // ИНН
   "kpp": "222222222", // КПП
   "settlement_account": "11111111111111111111", // Расчетный счет
   "bank": "Сбер", // Банк, в котором открыт расчетный счет
   "corr_account": "30111111111111111111", // Корреспондентский счет
   "bank_bic": "124444444", // БИК банка
   "is_self_employment": false, // Признак самозанятости
   "director_firstname": "Имя", // Имя руководителя
   "director_firstname_decline": true, // Признак склонения имени
```
руководителя
```
   "director_lastname": "фамилия", // Фамилия руководителя
   "director_lastname_decline": true, // Признак склонения фамилии
```
руководителя
```
   "director_fathername": "отчество", // Отчество руководителя
   "director_fathername_decline": true, // Признак склонения отчества
```
руководителя
```
   "director_no_fathername": false, // Флаг отсутствия отчества у
```
руководителя
```
   "comment": null, // Дополнительный комментарий
   "signers": [], // Подписанты (массив объектов с данными
```
уполномоченных лиц)
```
   "passport": { // Паспортные данные руководителя / ИП
       "birthplace": "Место рождения", // Место рождения
       "series": "2141", // Серия паспорта
       "number": "312415", // Номер паспорта
       "issued_by": "Кем выдан", // Кем выдан паспорт
       "issue_date": "2025-09-17", // Дата выдачи паспорта
       "code": "290001", // Код подразделения
       "no_registration": false, // Признак отсутствия регистрации
       "permanent_registration": "Постоянная регистрация", // Адрес
```
постоянной регистрации
```
       "temporary_registration": "Временная регистрация" // Адрес
```
временной регистрации
```
   },
   "emails": [ // Email-адреса организации/ИП
       {
            "email": "aaa@mail.ru" // Email
       }

         ],
        "phones": [ // Телефоны организации/ИП
            {
                "phone": "79008006655" // Телефон в формате
            }
        ]
}
```
Ответ:

```
{
        "status": "success",
        "data": {
            "registration_date": "2025-09-17",
            "birthdate": "1998-09-03",
            "legal_name": null,
            "legal_type": "ip",
            "legal_address": "Юридический адрес",
            "actual_address": "Фактический адрес",
            "ogrn": "111111111111111",
            "inn": "405881403100",
            "kpp": "222222222",
            "settlement_account": "11111111111111111111",
            "bank": "Сбер",
            "corr_account": "30111111111111111111",
            "bank_bic": "124444444",
            "is_self_employment": false,
            "director_firstname": "Имя",
            "director_firstname_decline": true,
            "director_lastname": "фамилия",
            "director_lastname_decline": true,
            "director_fathername": "отчество",
            "director_fathername_decline": true,
            "director_no_fathername": false,
            "comment": null,
            "company_id": 936,
            "updated_at": "2025-09-17 18:06:36",
            "created_at": "2025-09-17 18:06:36",
            "id": 945,
            "passport": {
                "birthplace": "Место рождения",
                "series": "2141",
                "number": "312415",
                "issued_by": "Кем выдан",
                "issue_date": "2025-09-17",
                "code": "290001",
                "no_registration": false,

             "permanent_registration": "Постоянная регистрация",
            "temporary_registration": "Временная регистрация",
            "client_id": 945,
            "client_type": "App\\Models\\Client\\ClientLegal",
            "child_id": null,
            "company_id": 936,
            "updated_at": "2025-09-17 18:06:36",
            "created_at": "2025-09-17 18:06:36",
            "id": 2612,
            "hashes": []
        },
        "phones": [
            {
                "phone": "79008006655"
            }
        ],
        "emails": [
            {
                "email": "aaa@mail.ru"
            }
        ]
    }
}
```
## 9. Клиенты (юридические лица) - Обновление
URL: PUT|PATCH
https://agencies-p.topnlab.ru/public/client-legals/{clientLegalId}
Тело запроса:

```
{
    "key": "asd", // ключ партнера
    "entity_id": 47894422, // ID сущности
    "entity_type": 2, // Тип сущности
    "registration_date": "2025-09-17", // Дата регистрации ИП
    "birthdate": "1998-09-03", // Дата рождения (актуально для ИП)
    "legal_name": null, // Полное юридическое название (для юр. лиц)
    "legal_type": "ip", // Тип юр. лица (например: ooo, ao, ip)
    "legal_address": "Юридический адрес", // Юридический адрес
    "actual_address": "Фактический адрес", // Фактический адрес
    "ogrn": "111111111111111", // ОГРН
    "inn": "405881403100", // ИНН
    "kpp": "222222222", // КПП
    "settlement_account": "11111111111111111111", // Расчетный счет
    "bank": "Сбер", // Банк, в котором открыт расчетный счет

     "corr_account": "30111111111111111111", // Корреспондентский счет
    "bank_bic": "124444444", // БИК банка
    "is_self_employment": false, // Признак самозанятости
    "director_firstname": "Имя", // Имя руководителя
    "director_firstname_decline": true, // Признак склонения имени
руководителя
    "director_lastname": "фамилия", // Фамилия руководителя
    "director_lastname_decline": true, // Признак склонения фамилии
руководителя
    "director_fathername": "отчество", // Отчество руководителя
    "director_fathername_decline": true, // Признак склонения отчества
руководителя
    "director_no_fathername": false, // Флаг отсутствия отчества у
руководителя
    "comment": null, // Дополнительный комментарий
    "signers": [], // Подписанты (массив объектов с данными
уполномоченных лиц)
    "passport": { // Паспортные данные руководителя ИП
        "birthplace": "Место рождения", // Место рождения
        "series": "2141", // Серия паспорта
        "number": "312415", // Номер паспорта
        "issued_by": "Кем выдан", // Орган, выдавший паспорт
        "issue_date": "2025-09-17", // Дата выдачи паспорта
        "code": "290001", // Код подразделения
        "no_registration": false, // Признак отсутствия регистрации
        "permanent_registration": "Постоянная регистрация", // Адрес
постоянной регистрации
        "temporary_registration": "Временная регистрация" // Адрес
временной регистрации
    },
    "emails": [ // Email-адреса организации/ИП
        {
             "email": "aaa@mail.ru" // Email
        }
    ],
    "phones": [ // Телефоны организации/ИП
        {
             "phone": "79008006655" // Телефон в формате MSISDN
        }
    ]
}
```
Ответ:

```
{
        "status": "success",
        "data": {

"id": 945,
```
"parent_id": null,
"company_id": 936,
"registration_date": "2025-09-17",
"birthdate": "1998-09-03",
"legal_name": null,
"legal_type": "ip",
"legal_address": "Юридический адрес",
"actual_address": "Фактический адрес",
"ogrn": "111111111111111",
"inn": "405881403100",
"kpp": "222222222",
"settlement_account": "11111111111111111111",
"bank": "Сбер",
"corr_account": "30111111111111111111",
"bank_bic": "124444444",
"is_self_employment": false,
"director_firstname": "Имя",
"director_firstname_decline": true,
"director_lastname": "фамилия",
"director_lastname_decline": true,
"director_fathername": "отчество",
"director_fathername_decline": true,
"director_no_fathername": false,
"comment": null,
"created_at": "2025-09-17 18:06:36",
"updated_at": "2025-09-17 18:06:36",
"deleted_at": null,
"passport": {
```
   "id": 2612,
   "parent_id": null,
   "company_id": 936,
   "client_type": "App\\Models\\Client\\ClientLegal",
   "client_id": 945,
   "child_id": null,
   "nationality": null,
   "nationality_country": null,
   "birthplace": "Место рождения",
   "series": "2141",
   "number": "312415",
   "issued_by": "Кем выдан",
   "issue_date": "2025-09-17",
   "code": "290001",
   "no_registration": false,
   "permanent_registration": "Постоянная регистрация",
   "temporary_registration": "Временная регистрация",
   "created_at": "2025-09-17 18:06:36",

             "updated_at": "2025-09-17 18:08:07",
            "deleted_at": null,
            "hashes": []
        },
        "phones": [
            {
                "phone": "79008006655"
            }
        ],
        "emails": [
            {
                "email": "aaa@mail.ru"
            }
        ]
    }
}
```
## 10. Подписанты клиентов (юридических лиц) - Создание
URL: POST
https://agencies-p.topnlab.ru/public/client-legals/{clientLegalId}/signers
Тело запроса:

```
{
    "key": "asd", // ключ партнера
    "entity_id": 7023381, // ID сущности
    "entity_type": 3, // Тип сущности
    "firstname": "Имя", // Имя подписанта
    "firstname_decline": true, // Признак склонения имени
    "lastname": "Фамилия", // Фамилия подписанта
    "lastname_decline": true, // Признак склонения фамилии
    "fathername": "Отчество", // Отчество подписанта
    "fathername_decline": true, // Признак склонения отчества
    "no_fathername": false, // Флаг отсутствия отчества
    "gender": "female", // Пол (male / female)
    "position": "Должность", // Должность подписанта
    "position_by_act": "charter", // Действующий(ая) на основании
    "act_number": null, // Номер документа, подтверждающего полномочия
(если есть)
    "act_date": null, // Дата документа, подтверждающего полномочия
    "act_date_limit": null, // Срок действия документа (если ограничен)
    "finance_limit": "10000" // Лимит финансовых полномочий (например:
сумма, либо null)
}

Ответ:

{
        "status": "success",
        "data": {
            "firstname": "Тест 1",
            "firstname_decline": true,
            "lastname": "Тест 1",
            "lastname_decline": true,
            "fathername": "Тест 1",
            "fathername_decline": true,
            "no_fathername": false,
            "gender": "female",
            "position": "Тест 1",
            "position_by_act": "charter",
            "act_number": null,
            "act_date": null,
            "act_date_limit": null,
            "finance_limit": "ыапыва",
            "client_legal_id": 456,
            "company_id": 936,
            "updated_at": "2025-09-11 11:56:27",
            "created_at": "2025-09-11 11:56:27",
            "id": 169
        }
}
```
## 11. Подписанты клиентов (юридических лиц) - Обновление
URL: PUT|PATCH
https://agencies-p.topnlab.ru/public/client-legals/{clientLegalId}/signers
/{signerId}
Тело запроса:

```
{
        "key": "asd",
        "entity_id": 7023381,
        "entity_type": 3,
        "firstname": "Имя", // Имя подписанта
        "firstname_decline": true, // Признак склонения имени
        "lastname": "Фамилия", // Фамилия подписанта
        "lastname_decline": true, // Признак склонения фамилии
        "fathername": "Отчество", // Отчество подписанта

     "fathername_decline": true, // Признак склонения отчества
    "no_fathername": false, // Флаг отсутствия отчества
    "gender": "female", // Пол (male / female)
    "position": "Должность", // Должность подписанта
    "position_by_act": "charter", // Действующий(ая) на основании
    "act_number": null, // Номер документа, подтверждающего полномочия
(если есть)
    "act_date": null, // Дата документа, подтверждающего полномочия
    "act_date_limit": null, // Срок действия документа (если ограничен)
    "finance_limit": "10000" // Лимит финансовых полномочий (например:
сумма, либо null)
}
```
Ответ:

```
{
        "status": "success",
        "data": {
            "id": 169,
            "parent_id": null,
            "company_id": 936,
            "client_legal_id": 456,
            "firstname": "Тест 2",
            "firstname_decline": true,
            "lastname": "Тест 2",
            "lastname_decline": true,
            "fathername": "Тест 2",
            "fathername_decline": true,
            "no_fathername": false,
            "gender": "female",
            "position": "Тест 2",
            "position_by_act": "charter",
            "act_number": null,
            "act_date": null,
            "act_date_limit": null,
            "finance_limit": "Тест 2",
            "created_at": "2025-09-11 11:56:27",
            "updated_at": "2025-09-11 11:59:15",
            "deleted_at": null
        }
}
```
