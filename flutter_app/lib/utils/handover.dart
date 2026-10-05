// Whether what a listing sells can be delivered at all.
//
// Land and buildings don't move: the buyer views them where they are, and
// ownership passes by a title transfer. The server drops any delivery answer
// for them and tells Zeno so (backend/api/domains/listings/handover.py, which
// this list must match); the app stops asking, and shows buyers what happens
// instead of "Delivery not stated".

const notDeliverableCategories = {'land', 'property'};

const inPlaceTitle = 'Viewed on site';
const inPlaceBody = 'Not delivered - it stays where it is. View it on site; '
    'ownership passes by a title transfer.';

bool isDeliverableCategory(String? category) =>
    category == null || !notDeliverableCategories.contains(category.trim().toLowerCase());
