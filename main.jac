"""Main entry point for trip-planner."""

import from byllm.lib { Model }
# Client-side imports (useState is auto-injected when using `has` variables)
cl import "./styles.css";
cl import from react { useEffect }

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

enum MealType { BREAKFAST, LUNCH, DINNER }

obj Meal {
    has restaurant: str;
    has mealType: MealType;
    has cost: float;
}
sem Meal.cost = "Estimated cost for a meal in USD";
sem Meal.mealType = "The type of the meal, either BREAKFAST, LUNCH, or DINNER";
sem Meal.restaurant = "The name of the restaurant.";

def find_meal(city: str) -> Meal by llm();
sem find_meal = "Find a restaurant to eat at in the given city and the best type of meal to get there (breakfast, lunch, or dinner) and estimate the cost of the meal";

def:pub add_meal(trip: Trip) -> Meal {
    city = trip.destination;
    meal = find_meal(city);
    trip.meals.append(meal);
    return meal;
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
        input_text:str = "";

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

    return 
        <div class="container">
            <h1>Trip Planner</h1>
            <div class="input-row">
                <input
                    class="input"
                    value={input_text}
                    onChange={lambda e: ChangeEvent { input_text = e.target.value; }}
                    onKeyPress={lambda e: KeyboardEvent {
                        if e.key == "Enter" { add_new_trip(); }
                    }}
                    placeholder="What needs to be done today?"
                />
                <button class="btn-add" onClick={add_new_trip}>Add</button>
            </div>
            {[
                <div key={jid(t)} class="task-item">
                    <span class="task-title">{t.destination}</span>
                </div> for t in trips
            ]}
        </div>;
}
