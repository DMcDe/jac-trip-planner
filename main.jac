"""Main entry point for trip-planner."""

import from byllm.lib { Model }
import os, requests;
import from dotenv { load_dotenv }

cl import "./styles.css";

glob llm = Model(model_name="huggingface/Qwen/Qwen2.5-Coder-7B-Instruct");

node Trip {
    has destination: str,
        flights: list[Flight] = [],
        stays: list[Stay] = [],
        meals: list[Meal] = [],
        total_cost: float = 0;
}

obj Flight {
    has src: str;
    has dst: str;
    has airline: str;
    has flight_num: str;
    has cost: float;
}

obj Stay {
    has name: str;
    has nights: int;
    has checkin: str;
    has checkout: str;
    has cost: float;
}

obj Meal {
    has restaurant: str;
    has mealType: str;
    has cost: float;
}

"""Search the live web for restaurant options in a city and return concise results."""
def search_web(query: str) -> str {
    import from typing { Any }

    load_dotenv();
    api_key = os.getenv("TAVILY_API_KEY");
    if not api_key {
        return "Web search unavailable: set TAVILY_API_KEY in the server environment.";
    }

    resp: Any = requests.post(
        "https://api.tavily.com/search",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json"
        },
        json={
            "query": query,
            "topic": "general",
            "search_depth": "advanced",
            "max_results": 5,
            "include_answer": True
        },
        timeout=20
    );
    resp.raise_for_status();
    body: Any = resp.json();

    answer = body.get("answer", "");
    results: Any = body.get("results", []);
    snippets: list[str] = [];
    for item in results {
        row: Any = item;
        line = f"{row.get('title', 'Untitled')}: {row.get('content', '')}";
        snippets = snippets + [line];
    }
    return "\n".join(([answer] if answer else []) + snippets);
}
sem search_web = "Use Tavily live web search to gather current public web information.";

def find_meal_with_context(city: str, web_context: str) -> list[Meal] by llm();
sem find_meal_with_context = "Given a city and live web search context about restaurants there, return exactly 5 Meal objects. Each mealType must be exactly one of these three strings (uppercase): BREAKFAST, LUNCH, DINNER — pick whichever fits that restaurant best. cost is estimated meal price in USD (a number). restaurant is the venue name.";


"""Map LLM or numeric junk to a display label; structured output often uses 1/2/3 or wrong ints."""
def normalize_meal_type(raw: str) -> str {
    s = str(raw).strip().upper();
    if s == "1" or s == "BREAKFAST" {
        return "BREAKFAST";
    }
    if s == "2" or s == "LUNCH" {
        return "LUNCH";
    }
    if s == "3" or s == "DINNER" {
        return "DINNER";
    }
    if "BREAKFAST" in s {
        return "BREAKFAST";
    }
    if "LUNCH" in s {
        return "LUNCH";
    }
    if "DINNER" in s {
        return "DINNER";
    }
    return "DINNER";
}

"""Apply normalize_meal_type to each meal (mutate in place for graph persistence)."""
def normalize_meals(meals: list[Meal]) -> list[Meal] {
    for m in meals {
        m.mealType = normalize_meal_type(m.mealType);
    }
    return meals;
}

"""Enrich a trip with meal ideas (server-side graph + LLM). Client must pass *trip_id* (string); search uses that trip's *destination* (HTTP API rejects Trip objects in the body)."""
def:pub add_meal(trip_id: str) -> list[Meal] {
    for t in [root()-->][?:Trip] {
        if str(jid(t)) == trip_id {
            city = t.destination.strip();
            web_context = search_web(
                f"most popular restaurants in {city} with must try dishes and affordable price range"
            );
            meals = normalize_meals(find_meal_with_context(city, web_context));
            t.meals = t.meals + meals;
            return t.meals;
        }
    }
    return [];
}

"""Add a trip and return it"""
def:pub create_trip(destination: str) -> Trip {
    trip = root() ++> Trip(destination=destination);
    return trip[0];
}

"""Add a flight to a trip"""
def:pub add_flight(trip: Trip, flight: Flight) -> Flight {
    trip.flights.append(flight);
    return flight;
}

"""Get all trips."""
def:pub get_trips -> list[Trip] {
    return [root()-->][?:Trip];
}

cl def:pub app -> JsxElement {
    has trips: list[Trip] = [],
        input_text: str = "";

    async can with entry {
        trips = await get_trips();
    }

    async def add_new_trip {
        if input_text.strip() {
            trip = await create_trip(input_text.strip());
            trips = trips + [trip];
            input_text = "";
        }
    }

    async def add_new_meal(trip: Trip) {
        trip.meals = await add_meal(str(jid(trip)));
        trips = [x for x in trips];
    }

    def meal_rows(trip: Trip) -> list[JsxElement] {
        out: list[JsxElement] = [];
        idx: int = 0;
        for m in trip.meals {
            label = f"{m.restaurant} · {m.mealType} · " + str(m.cost) + " USD";
            meal_key = str(jid(trip)) + "-meal-" + str(idx);
            out = out + [
                <li key={meal_key} class="meal-item">
                    {label}
                </li>
            ];
            idx += 1;
        }
        return out;
    }

    def trip_card(trip: Trip) -> JsxElement {
        return
            <article class="trip-card" key={jid(trip)}>
                <div class="trip-card-head">
                    <h2 class="trip-destination">{trip.destination}</h2>
                    <button
                        type="button"
                        class="btn btn-secondary"
                        onClick={lambda { add_new_meal(trip); }}
                    >
                        Find meals
                    </button>
                </div>
                {
                    <ul class="meal-list">{meal_rows(trip)}</ul>
                    if len(trip.meals) > 0
                    else <p class="trip-empty">No meal ideas yet — use Find meals for AI suggestions.</p>
                }
            </article>;
    }

    def trip_grid_cards() -> list[JsxElement] {
        return [trip_card(trip=t) for t in trips];
    }

    return
        <div class="app">
            <header class="site-header">
                <div class="site-header-inner">
                    <p class="eyebrow">Jac trip planner</p>
                    <h1 class="site-title">Plan trips and discover meals</h1>
                    <p class="site-lede">
                        Add a destination, then pull restaurant ideas backed by live search and the model.
                    </p>
                </div>
            </header>
            <main class="main">
                <section class="panel panel-add" aria-label="Add destination">
                    <label class="label" for="dest-input">Where to next?</label>
                    <div class="add-row">
                        <input
                            id="dest-input"
                            class="input"
                            value={input_text}
                            onChange={lambda e: ChangeEvent { input_text = e.target.value; }}
                            onKeyDown={lambda e: KeyboardEvent {
                                if e.key == "Enter" { add_new_trip(); }
                            }}
                            placeholder="e.g. Lisbon, Tokyo, Austin"
                            autoComplete="off"
                        />
                        <button type="button" class="btn btn-primary" onClick={add_new_trip}>
                            Add trip
                        </button>
                    </div>
                </section>
                <section class="trips-section" aria-label="Your trips">
                    {
                        <div class="trip-grid">{trip_grid_cards()}</div>
                        if len(trips) > 0
                        else
                            <div class="empty-state">
                                <p class="empty-title">No trips yet</p>
                                <p class="empty-copy">Enter a city above to start your list.</p>
                            </div>
                    }
                </section>
            </main>
        </div>;
}
